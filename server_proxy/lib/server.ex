defmodule Server do
  require Logger

  def start() do
    {:ok, parent_pid} = Task.start_link(fn -> loop(%{}) end)

    send(parent_pid, {:start})
  end

  defp send_create_room_message(socket_pid, negociator_pid) do
    request_id = UUID.uuid4()

    message = %Messages.CreateRoom{requestId: request_id} |> JSON.encode!()

    WebSockex.send_frame(socket_pid, {:text, message})

    send(negociator_pid, {:add_pending, request_id, self()})

    receive do
      {:resolved, value} -> IO.inspect(value)
    end
  end

  defp start_connection(%{"sdpCert" => cert, "roomId" => room_id, "sourceUserId" => user_id}) do
    {:ok, pc} =
      ExWebRTC.PeerConnection.start_link(ice_servers: [%{urls: "stun:stun.l.google.com:19302"}])

    cert = cert |> JSON.decode!() |> ExWebRTC.SessionDescription.from_json()
    ExWebRTC.PeerConnection.set_remote_description(pc, cert)

    {:ok, answer} = ExWebRTC.PeerConnection.create_answer(pc)
    ExWebRTC.PeerConnection.set_local_description(pc, answer)
    request_id = UUID.uuid4()

    message =
      JSON.encode!(%Messages.OfferReply{
        requestId: request_id,
        roomId: room_id,
        toUser: user_id,
        sdpCert: answer |> ExWebRTC.SessionDescription.to_json() |> JSON.encode!()
      })

    {message, room_id, user_id, pc}
  end

  defp loop(state) do
    receive do
      {:start} ->
        {:ok, negociator_pid, socket_pid} = SocketHandler.start_link(%{}, self())

        send(self(), {:add_socket, socket_pid})

        send_create_room_message(socket_pid, negociator_pid)

        loop(state)

      {:sdp_offered, data} ->
        {message, room_id, user_id, peer_connection} = start_connection(data)
        Map.get(state, "socket_pid") |> WebSockex.send_frame({:text, message})

        {:ok, pid} = WebRTCHandler.start_link(peer_connection, room_id, user_id, self())

        Map.put(state, peer_connection, pid)
        |> Map.put("#{room_id}_#{user_id}", {peer_connection, pid})
        |> loop()

      {:add_socket, socket_pid} ->
        Map.put(state, "socket_pid", socket_pid) |> loop()

      {:ice_candidate,
       %{
         "sourceUserId" => source_user_id,
         "sourceRoomId" => source_room_id,
         "ICECandidate" => ice_candidate
       }} ->
        ice_candidate = JSON.decode!(ice_candidate) |> ExWebRTC.ICECandidate.from_json()

        {pc, _} = Map.get(state, "#{source_room_id}_#{source_user_id}")

        ExWebRTC.PeerConnection.add_ice_candidate(pc, ice_candidate)

        loop(state)

      {:send_message, msg} ->
        Map.get(state, "socket_pid") |> WebSockex.send_frame({:text, msg})
        loop(state)

      {:ex_webrtc, pc, msg} ->
        Map.get(state, pc)
        |> send(msg)

        loop(state)

      unknown ->
        IO.inspect("unknown message received #{unknown}")
        loop(state)
    end
  end
end

defmodule WebRTCHandler do
  require Logger

  defstruct [:peer_connection, :room_id, :user_id, :parent_pid, :decoder_pid]

  def start_link(peer_connection, room_id, user_id, parent_pid) do
    {:ok, pid} =
      Task.start_link(fn ->
        loop(%WebRTCHandler{
          peer_connection: peer_connection,
          room_id: room_id,
          user_id: user_id,
          parent_pid: parent_pid
        })
      end)
  end

  defp loop(
         %{
           peer_connection: pc,
           room_id: room_id,
           user_id: user_id,
           parent_pid: parent_pid,
           decoder_pid: decoder_pid
         } = state
       ) do
    receive do
      {:data, _data_channel, data} ->
        Logger.warning("Received data from #{room_id} #{user_id}")

        {new_state, decoder_pid} =
          if decoder_pid == nil do
            {:ok, decoder_pid} = WebRTCMessageDecoder.start_link(self())
            {Map.put(state, :decoder_pid, decoder_pid), decoder_pid}
          else
            {state, decoder_pid}
          end

        send(decoder_pid, {:receive_message, data})
        loop(new_state)

      {:ice_candidate, candidate} ->
        request_id = UUID.uuid4()

        message =
          JSON.encode!(%Messages.SendICE{
            requestId: request_id,
            roomId: room_id,
            targetUserId: user_id,
            iceCandidate: candidate |> ExWebRTC.ICECandidate.to_json() |> JSON.encode!()
          })

        send(parent_pid, {:send_message, message})

        loop(state)

      {:WebRTCDecoded, decoded} ->
        IO.inspect(decoded)
        loop(state)

      unknown ->
        IO.inspect("unknown message received #{unknown}")
        loop(state)
    end
  end
end
