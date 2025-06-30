defmodule ClientSocketHandler do
  use GenServer

  @impl true
  def init(init_arg \\ %{}) do
    {:ok, init_arg}
  end

  @impl true
  def handle_info(
        {:sdp_offered, %{"sdpCert" => cert, "roomId" => _, "sourceUserId" => user_id}},
        state
      ) do
    cert = cert |> JSON.decode!() |> ExWebRTC.SessionDescription.from_json()
    :ok = ExWebRTC.PeerConnection.set_remote_description(state.peer_connection, cert)

    GenServer.cast(state.webrtc_handler, {:add_user_id, user_id})

    {:noreply, state}
  end

  @impl true
  def handle_info(
        {:ice_candidate,
         %{
           "ICECandidate" => ice_candidate
         }},
        state
      ) do
    ice_candidate = JSON.decode!(ice_candidate) |> ExWebRTC.ICECandidate.from_json()

    ExWebRTC.PeerConnection.add_ice_candidate(state.peer_connection, ice_candidate)

    {:noreply, state}
  end

  @impl true
  def handle_cast(
        {:add_connection, peer_connection, data_channel, webrtc_handler},
        state
      ) do
    new_state =
      Map.put(state, :peer_connection, peer_connection)
      |> Map.put(:data_channel, data_channel)
      |> Map.put(:webrtc_handler, webrtc_handler)

    {:noreply, new_state}
  end
end

defmodule Client do
  use GenServer
  require Logger

  @impl true
  def init(state \\ %{}) do
    {:ok, state}
  end

  def join(room_id) do
    {:ok, parent_pid} = GenServer.start_link(Client, %{})

    msg = GenServer.call(parent_pid, {:start, room_id, self()}, :infinity)

    {parent_pid, msg}
  end

  def leave(parent_pid, room_id) do
    GenServer.call(parent_pid, {:leave, room_id})
  end

  defp send_leave_room_message(socket_pid, negociator_pid, room_id) do
    request_id = UUID.uuid4()

    message = JSON.encode!(%Messages.LeaveRoom{requestId: request_id, roomId: room_id})

    WebSockex.send_frame(socket_pid, {:text, message})

    send(negociator_pid, {:add_pending, request_id, self()})

    receive do
      {:resolved, value} -> value
    end
  end

  defp send_join_room_message(socket_pid, negociator_pid, room_id) do
    request_id = UUID.uuid4()

    message = JSON.encode!(%Messages.JoinRoom{requestId: request_id, roomId: room_id})

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

  @impl true
  def handle_call({:send_message, header, body, request_id}, _from, state) do
    {room, owner} = Map.get(state, "connection")

    {data_channel, pc} =
      Map.get(state, room)
      |> Map.get(owner)

    encoded = WebRTCMessageEncoder.encode_message(header, body, request_id)

    Enum.each(encoded, fn part ->
      ExWebRTC.PeerConnection.send_data(pc, data_channel, part)
    end)

    {:reply, nil, state}
  end

  @impl true
  def handle_call({:start, room_id, callback_pid}, _from, state) do
    {:ok, sock_handler_pid} = GenServer.start_link(ClientSocketHandler, %{})
    {:ok, negociator_pid, socket_pid} = SocketHandler.start_link(%{}, sock_handler_pid)

    {pc, data_channel, room, owner} =
      send_join_room_message(socket_pid, negociator_pid, room_id)

    {:ok, pid} = GenServer.start(WebRTCHandler, {pc, room_id, nil, self()})

    GenServer.cast(sock_handler_pid, {:add_connection, pc, data_channel, pid})

    new_state =
      Map.put(state, "connection", {room, owner})
      |> Map.put("handler_pid", pid)
      |> Map.put(room, Map.put(%{}, owner, {data_channel, pc}))
      |> Map.put("callback_pid", callback_pid)
      |> Map.put("pids", {negociator_pid, socket_pid})

    receive do
      {:ex_webrtc, _, {:ice_connection_state_change, :completed}} ->
        {:reply, "connection established", new_state}

      {:ex_webrtc, _, {:ice_connection_state_change, :failed}} ->
        {:reply, "connection failed", new_state}
    end
  end

  @impl true
  def handle_call({:leave, room_id}, _from, state) do
    {negociator_pid, socket_pid} = Map.get(state, "pids")
    send_leave_room_message(socket_pid, negociator_pid, room_id)

    {:reply, nil, state}
  end

  @impl true
  def handle_cast({:ping_server}, state) do
    {room, owner} = Map.get(state, "connection")

    {data_channel, pc} =
      Map.get(state, room)
      |> Map.get(owner)

    ExWebRTC.PeerConnection.send_data(pc, data_channel, "ping")

    {:noreply, state}
  end

  @impl true
  def handle_info(msg, state) do
    case msg do
      {:WebRTCDecoded, _room_id, _user_id, "pong", "pong"} ->
        Map.get(state, "callback_pid")
        |> send({:WebRTCDecoded, "pong", "pong"})

        {:noreply, state}

      {:WebRTCDecoded, _room_id, _user_id, request_id, message} ->
        Map.get(state, "callback_pid")
        |> send({:WebRTCDecoded, request_id, message})

        {:noreply, state}

      {:ex_webrtc, _pc, {:data, _data_channel, "pong"}} ->
        Map.get(state, "callback_pid")
        |> send({:WebRTCDecoded, "pong", "pong"})

        {:noreply, state}

      {:ex_webrtc, _pc, {:data, _, _} = msg} ->
        Map.get(state, "handler_pid")
        |> GenServer.cast(msg)

        {:noreply, state}

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

        {:noreply, state}

      _unknown ->
        Logger.debug("CLINET RECIEVED UNHANDLED MESSAGE")

        {:noreply, state}
    end
  end
end
