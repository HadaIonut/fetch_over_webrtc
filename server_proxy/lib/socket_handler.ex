defmodule SocketHandler do
  use WebSockex
  require Logger

  @reply_message_types ["offer", "join", "create"]

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
    Logger.info("Connected!")
    {:ok, state}
  end

  def handle_frame({:text, msg}, state) do
    Logger.info("Received Message: #{msg}")

    case JSON.decode(msg) do
      {:ok, %{"type" => type, "requestId" => request_id} = res}
      when type in @reply_message_types ->
        send(state.negociator_pid, {:resolve_request, request_id, res})

      {:ok, %{"type" => type} = res} when type == "userJoined" ->
        Logger.info("user joined")

      {:ok, %{"type" => type} = res} when type == "userOffer" ->
        Logger.info("user offer received")

        send(state.parent, {:sdp_offered, res})

      {:ok, %{"type" => type} = res} when type == "userOfferReply" ->
        Logger.info("user offer reply received")

        send(state.parent, {:sdp_offered, res})

      {:ok, %{"type" => type} = res} when type == "ICECandidate" ->
        Logger.info("Ice Candidate received ")
        send(state.parent, {:ice_candidate, res})

      {:ok, _} ->
        IO.inspect("unkonwn msg")

      {:error, msg} ->
        IO.inspect(msg)
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
        Map.get(state, request_id)
        |> send({:resolved, value})

        Map.delete(state, request_id) |> loop()
    end

    loop(state)
  end
end
