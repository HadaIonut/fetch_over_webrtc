defmodule WebRTCHandler do
  use GenServer
  require Logger

  defstruct [:peer_connection, :room_id, :user_id, :parent_pid, :decoder_pid]

  defp via_name(id) do
    {:via, Registry, {Registry.UserNameRegistry, {:webrtc_handler, id}}}
  end

  def start_link(id) do
    GenServer.start_link(__MODULE__, %{}, name: via_name(id))
  end

  @impl true
  def init({peer_connection, room_id, user_id, parent_pid}) do
    {:ok,
     %WebRTCHandler{
       peer_connection: peer_connection,
       room_id: room_id,
       user_id: user_id,
       parent_pid: parent_pid
     }}
  end

  @impl true
  def init(_) do
    {:ok, %WebRTCHandler{}}
  end

  @impl true
  def handle_cast({:add_user_id, user_id}, state) do
    {:noreply, Map.put(state, :user_id, user_id)}
  end

  @impl true
  def handle_cast(
        {:set_data, {peer_connection, room_id, user_id, parent_pid}},
        _
      ) do
    Logger.debug("setting rtc handler data")

    {:noreply,
     %WebRTCHandler{
       peer_connection: peer_connection,
       room_id: room_id,
       user_id: user_id,
       parent_pid: parent_pid
     }}
  end

  @impl true
  def handle_cast(
        {:data, _data_channel, "pong"},
        %{parent_pid: parent_pid} = state
      ) do
    send(
      parent_pid,
      {:WebRTCDecoded, Map.get(state, :room_id), Map.get(state, :user_id), "pong", "pong"}
    )

    {:noreply, state}
  end

  @impl true
  def handle_cast(
        {:data, _data_channel, "ping"},
        %{parent_pid: parent_pid} = state
      ) do
    send(
      parent_pid,
      {:WebRTCDecoded, Map.get(state, :room_id), Map.get(state, :user_id), "pong", "pong"}
    )

    {:noreply, state}
  end

  @impl true
  def handle_cast(
        {:data, _data_channel, data},
        %{
          parent_pid: parent_pid,
          room_id: room_id,
          user_id: user_id,
          decoder_pid: decoder_pid
        } = state
      ) do
    Logger.info("Received data from #{room_id} #{user_id}")

    {new_state, decoder_pid} =
      if decoder_pid == nil do
        {:ok, decoder_pid} =
          GenServer.start_link(WebRTCMessageDecoder, {parent_pid, room_id, user_id})

        {Map.put(state, :decoder_pid, decoder_pid), decoder_pid}
      else
        {state, decoder_pid}
      end

    GenServer.cast(decoder_pid, {:receive_message, data})

    {:noreply, new_state}
  end

  @impl true
  def handle_cast(
        {:data_channel, data_channel},
        %{
          parent_pid: parent_pid,
          room_id: room_id,
          user_id: user_id
        } = state
      ) do
    send(parent_pid, {:opened_data_channel, room_id, user_id, Map.get(data_channel, :ref)})
    {:noreply, state}
  end

  @impl true
  def handle_cast(
        {:ice_candidate, candidate},
        %{
          parent_pid: parent_pid,
          room_id: room_id,
          user_id: user_id
        } = state
      ) do
    request_id = UUID.uuid4()

    message =
      JSON.encode!(%Messages.SendICE{
        requestId: request_id,
        roomId: room_id,
        targetUserId: user_id,
        iceCandidate: candidate |> ExWebRTC.ICECandidate.to_json() |> JSON.encode!()
      })

    send(parent_pid, {:send_message, message})

    {:noreply, state}
  end

  @impl true
  def handle_cast(
        {:ice_connection_state_change, :completed},
        state
      ) do
    Logger.debug("CONNECTION ESTABLISHED")

    {:noreply, state}
  end

  @impl true
  def handle_cast(
        {:ice_connection_state_change, :failed},
        state
      ) do
    {:stop, :shutdown, state}
  end

  @impl true
  def handle_cast(
        {:connection_state_change, :failed},
        state
      ) do
    {:stop, :shutdown, state}
  end

  @impl true
  def handle_cast(
        {:data_channel_state_change, _, :closed},
        state
      ) do
    {:stop, :shutdown, state}
  end

  @impl true
  def handle_cast(unknown, state) do
    Logger.debug("UNKNOWN MESSAGE RECEIVED, #{inspect(unknown)}")

    {:noreply, state}
  end
end
