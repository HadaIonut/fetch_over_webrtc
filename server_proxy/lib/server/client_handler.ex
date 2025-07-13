defmodule ClientHandler do
  require Logger
  use GenServer

  @impl true
  def init(init_arg \\ %{}) do
    Logger.debug("SERVER: init client handler")
    {:ok, init_arg}
  end

  @impl true
  def handle_cast({:add_ice_certificate, ice_certificate}, state) do
    ExWebRTC.PeerConnection.add_ice_candidate(state.peer_connection, ice_certificate)

    Logger.debug("SERVER: add_ice_certificate finished")
    {:noreply, state}
  end

  @impl true
  def handle_cast({:start_connection, room_id, user_id, sdp_cert, websock_pid}, state) do
    Logger.debug("SERVER: start_connection started")
    id = "#{room_id}_#{user_id}"

    proxy_pid = via_name(id, :server_proxy)

    {:ok, pc} =
      ExWebRTC.PeerConnection.start(ice_servers: [%{urls: "stun:stun.l.google.com:19302"}])

    sdp_cert = sdp_cert |> JSON.decode!() |> ExWebRTC.SessionDescription.from_json()
    ExWebRTC.PeerConnection.set_remote_description(pc, sdp_cert)

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

    WebSockex.send_frame(websock_pid, {:text, message})

    rtc_handler_pid = via_name(id, :webrtc_handler)

    GenServer.cast(rtc_handler_pid, {:set_data, {pc, room_id, user_id, self()}})

    new_state =
      Map.put(state, :room_id, room_id)
      |> Map.put(:user_id, user_id)
      |> Map.put(:websock_pid, websock_pid)
      |> Map.put(:rtc_handler_pid, rtc_handler_pid)
      |> Map.put(:peer_connection, pc)
      |> Map.put(:proxy_pid, proxy_pid)

    Logger.debug("SERVER: start_connection finished")

    {:noreply, new_state}
  end

  @impl true
  def handle_info({:WebRTCDecoded, _room_id, _user_id, "pong", "pong"}, state) do
    ExWebRTC.PeerConnection.send_data(state.peer_connection, state.data_channel, "pong")
    {:noreply, state}
  end

  @impl true
  def handle_info({:WebRTCDecoded, _room_id, _user_id, request_id, msg}, state) do
    ServerProxy.relay(
      state.proxy_pid,
      {:relay, msg, request_id, state.peer_connection, state.data_channel}
    )

    {:noreply, state}
  end

  @impl true
  def handle_info({:opened_data_channel, _room_id, _user_id, data_channel}, state) do
    {:noreply, Map.put(state, :data_channel, data_channel)}
  end

  @impl true
  def handle_info({:ex_webrtc, _, msg}, state) do
    GenServer.cast(state.rtc_handler_pid, msg)
    {:noreply, state}
  end

  @impl true
  def handle_info({:send_message, msg}, state) do
    WebSockex.send_frame(state.websock_pid, {:text, msg})
    {:noreply, state}
  end

  def handle_info(msg, state) do
    Logger.debug("UNKNOWN MESSAGE HANDLED BY CLIENT_HANDLER, #{inspect(msg)}")

    {:noreply, state}
  end

  defp via_name(id, flag) do
    {:via, Registry, {Registry.UserNameRegistry, {flag, id}}}
  end

  defp via_name(id) do
    {:via, Registry, {Registry.UserNameRegistry, {:user_worker, id}}}
  end

  def close(room_id, user_id) do
    GenServer.stop(via_name("#{room_id}_#{user_id}"))
  end

  def start_connection(client_handler_pid, room_id, user_id, sdp_cert, websock_pid) do
    Logger.debug(
      "SERVER: start_connection casted to #{via_name(client_handler_pid) |> inspect()}"
    )

    GenServer.cast(
      via_name(client_handler_pid),
      {:start_connection, room_id, user_id, sdp_cert, websock_pid}
    )
  end

  def add_ice_certificate(client_handler_pid, ice_certificate) do
    GenServer.cast(
      via_name(client_handler_pid),
      {:add_ice_certificate, ice_certificate}
    )
  end

  def gen_server_start_link(id) do
    GenServer.start_link(__MODULE__, %{}, name: via_name(id))
  end

  def start_link(id) do
    Supervisor.start_link(
      [
        %{
          id: "client",
          start: {ClientHandler, :gen_server_start_link, [id]},
          restart: :permanent
        },
        %{
          id: "proxy",
          start: {ServerProxy, :start_link, [id]},
          restart: :permanent
        },
        %{
          id: "rtcHandler",
          start: {WebRTCHandler, :start_link, [id]},
          restart: :permanent
        }
      ],
      strategy: :one_for_all,
      max_restarts: 0,
      max_seconds: 1
    )
  end
end
