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

        Map.put(state, "#{room_id}_#{user_id}", peer_connection)
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

        Map.get(state, "#{source_room_id}_#{source_user_id}")
        |> ExWebRTC.PeerConnection.add_ice_candidate(ice_candidate)

        loop(state)

      {:ex_webrtc, _pc, {:data, _data_channel, data}} ->
        Logger.warning("Received data: #{data}")

      {:ex_webrtc, pc, {:ice_candidate, candidate}} ->
        [room_id, user_id] =
          Map.keys(state)
          |> Enum.find(fn key -> Map.get(state, key) == pc end)
          |> String.split("_")

        request_id = UUID.uuid4()

        message =
          JSON.encode!(%Messages.SendICE{
            requestId: request_id,
            roomId: room_id,
            targetUserId: user_id,
            iceCandidate: candidate |> ExWebRTC.ICECandidate.to_json() |> JSON.encode!()
          })

        IO.inspect(message)

        Map.get(state, "socket_pid") |> WebSockex.send_frame({:text, message})

        loop(state)
    end
  end
end
