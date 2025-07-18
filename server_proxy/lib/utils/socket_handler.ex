defmodule SocketHandler do
  use WebSockex
  require Logger

  @reply_message_types ["offer", "join", "create", "leave"]

  def start_link(negociator_state, parent_pid) do
    {:ok, neg_pid} = Task.start_link(fn -> loop(negociator_state) end)

    {:ok, sock_pid} =
      WebSockex.start_link("ws://localhost:3000/ws", __MODULE__, %{
        negociator_pid: neg_pid,
        parent: parent_pid
      })

    {:ok, neg_pid, sock_pid}
  end

  def handle_connect(_conn, state) do
    {:ok, state}
  end

  def handle_frame({:text, msg}, state) do
    case JSON.decode(msg) do
      {:ok, %{"type" => type, "requestId" => request_id} = res}
      when type in @reply_message_types ->
        send(state.negociator_pid, {:resolve_request, request_id, res})

      {:ok, %{"type" => type, "room" => room}} when type == "userJoined" ->
        send(
          state.parent,
          {:user_joined,
           %{"roomId" => Map.get(room, "room_id"), "members" => Map.get(room, "members")}}
        )

      {:ok, %{"type" => type, "user" => user_id, "room" => room}} when type == "userLeft" ->
        send(
          state.parent,
          {:user_left,
           %{
             "roomId" => Map.get(room, "room_id"),
             "userId" => user_id,
             "members" => Map.get(room, "members")
           }}
        )

      {:ok, %{"type" => type} = res} when type == "ICECandidate" ->
        send(state.parent, {:ice_candidate, res})

      {:ok, %{"type" => type} = res} when type == "userOffer" ->
        send(state.parent, {:sdp_offered, res})

      {:ok, %{"type" => type} = res} when type == "userOfferReply" ->
        send(state.parent, {:sdp_offered, res})

      {:ok, %{"type" => type} = res} when type == "ICECandidate" ->
        send(state.parent, {:ice_candidate, res})

      {:ok, _} ->
        Logger.debug("unkonwn msg")

      {:error, msg} ->
        Logger.debug(inspect(msg))
    end

    {:ok, state}
  end

  def handle_disconnect(%{reason: {:local, reason}}, state) do
    Logger.info("Local close with reason: #{inspect(reason)}")
    {:ok, state}
  end

  def handle_disconnect(disconnect_map, state) do
    super(disconnect_map, state)
  end

  defp loop(state) do
    receive do
      {:add_pending, request_id, pid} ->
        Map.put(state, request_id, pid)
        |> loop()

      {:resolve_request, request_id, value} ->
        case Map.get(state, request_id) do
          nil ->
            nil

          val ->
            send(val, {:resolved, value})
        end

        Map.delete(state, request_id)
        |> loop()
    end

    loop(state)
  end
end
