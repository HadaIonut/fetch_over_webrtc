defmodule Client do
  require Logger

  def start(room_id) do
    {:ok, parent_pid} = Task.start_link(fn -> loop(%{}) end)

    send(parent_pid, {:start, room_id})
    parent_pid
  end

  def send_test_rtc_msg(parent_pid) do
    send(parent_pid, {:test})
  end

  defp send_join_room_message(socket_pid, negociator_pid, room_id) do
    request_id = UUID.uuid4()

    message = JSON.encode!(%Messages.JoinRoom{requestId: request_id, roomId: room_id})
    Logger.info("Sending message: #{message}")

    WebSockex.send_frame(socket_pid, {:text, message})

    send(negociator_pid, {:add_pending, request_id, self()})

    room_owner =
      receive do
        {:resolved, value} ->
          Map.get(value, "room") |> Map.get("owner_id")
      end

    {message, request_id, peer_connection, data_channel} = start_data_channel(room_id)

    WebSockex.send_frame(socket_pid, {:text, message})
    send(negociator_pid, {:add_pending, request_id, self()})

    receive do
      {:resolved, value} -> value
    end

    {peer_connection, data_channel, room_id, room_owner}
  end

  defp start_data_channel(room_id) do
    {:ok, pc} =
      ExWebRTC.PeerConnection.start_link(ice_servers: [%{urls: "stun:stun.l.google.com:19302"}])

    {:ok, data_channel} = ExWebRTC.PeerConnection.create_data_channel(pc, "ligma")

    {:ok, offer} = ExWebRTC.PeerConnection.create_offer(pc)
    ExWebRTC.PeerConnection.set_local_description(pc, offer)

    request_id = UUID.uuid4()

    val =
      JSON.encode!(%Messages.Offer{
        requestId: request_id,
        roomId: room_id,
        sdpCert: offer |> ExWebRTC.SessionDescription.to_json() |> JSON.encode!()
      })

    {val, request_id, pc, data_channel.ref}
  end

  defp loop(state) do
    receive do
      {:start, room_id} ->
        {:ok, negociator_pid, socket_pid} = SocketHandler.start_link(%{}, self())

        {pc, data_channel, room, owner} =
          send_join_room_message(socket_pid, negociator_pid, room_id)

        send(self(), {:add_connection, pc, data_channel, room, owner})

        Map.put(state, "connection", {room, owner})
        |> Map.put("pids", {negociator_pid, socket_pid})
        |> loop()

      {:sdp_offered, %{"sdpCert" => cert, "roomId" => room_id, "sourceUserId" => user_id}} ->
        {_, pc} = Map.get(state, room_id) |> Map.get(user_id)
        cert = cert |> JSON.decode!() |> ExWebRTC.SessionDescription.from_json()
        :ok = ExWebRTC.PeerConnection.set_remote_description(pc, cert)

        loop(state)

      {:add_connection, pc, data_channel, room, owner} ->
        room_val = Map.put(%{}, owner, {data_channel, pc})

        Map.put(state, room, room_val)
        |> loop()

      {:ice_candidate,
       %{
         "ICECandidate" => ice_candidate
       }} ->
        {room, owner} = Map.get(state, "connection")

        ice_candidate = JSON.decode!(ice_candidate) |> ExWebRTC.ICECandidate.from_json()

        {_, pc} =
          Map.get(state, room)
          |> Map.get(owner)

        ExWebRTC.PeerConnection.add_ice_candidate(pc, ice_candidate)

        loop(state)

      {:ex_webrtc, _, {:ice_candidate, candidate}} ->
        {room, owner} = Map.get(state, "connection")
        {_, socket_pid} = Map.get(state, "pids")

        request_id = UUID.uuid4()

        message =
          JSON.encode!(%Messages.SendICE{
            requestId: request_id,
            roomId: room,
            targetUserId: owner,
            iceCandidate: candidate |> ExWebRTC.ICECandidate.to_json() |> JSON.encode!()
          })

        WebSockex.send_frame(socket_pid, {:text, message})

        loop(state)

      {:test} ->
        {room, owner} = Map.get(state, "connection")

        {data_channel, pc} =
          Map.get(state, room)
          |> Map.get(owner)

        ExWebRTC.PeerConnection.send_data(pc, data_channel, "fjsdakfjdlks")
        loop(state)
    end
  end
end
