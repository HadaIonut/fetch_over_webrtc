defmodule Messages do
  defmodule CreateRoom do
    @derive Jason.Encoder
    defstruct [:requestId, type: "create"]
  end
end

defmodule Negociator do
  def start_link(state) do
    Task.start_link(fn -> loop(state) end)
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
  end
end

defmodule SocketHandler do
  use WebSockex
  require Logger

  def start_link(state) do
    WebSockex.start_link("ws://localhost:3000/ws", __MODULE__, state)
  end

  @spec send_message(pid, pid, String.t(), String.t()) :: :ok
  def send_message(sock_pid, negociator_pid, request_id, message) do
    Logger.info("Sending message: #{message}")
    WebSockex.send_frame(sock_pid, {:text, message})

    send(negociator_pid, {:add_pending, request_id, self()})

    receive do
      {:resolved, value} -> IO.inspect(value)
    end
  end

  def handle_connect(_conn, state) do
    Logger.info("Connected!")
    {:ok, state}
  end

  def handle_frame({:text, msg}, state) do
    Logger.info("Received Message: #{msg}")
    {:ok, res} = Jason.decode(msg)

    send(
      state.negociator_pid,
      {:resolve_request, Map.get(res, "requestId"), res}
    )

    {:ok, state}
  end

  def handle_disconnect(%{reason: {:local, reason}}, state) do
    Logger.info("Local close with reason: #{inspect(reason)}")
    {:ok, state}
  end

  def handle_disconnect(disconnect_map, state) do
    super(disconnect_map, state)
  end
end

defmodule Starter do
  def start() do
    {:ok, negociator_pid} = Negociator.start_link(%{})
    {:ok, sock_pid} = SocketHandler.start_link(%{negociator_pid: negociator_pid})

    request_id = UUID.uuid4()

    {:ok, val} = Jason.encode(%Messages.CreateRoom{requestId: request_id})

    SocketHandler.send_message(sock_pid, negociator_pid, request_id, val)
  end
end
