defmodule Server do
  require Logger
  use GenServer

  @impl true
  def init(init_arg \\ %{}) do
    {:ok, init_arg}
  end

  def start_link(_) do
    GenServer.start_link(__MODULE__, %{"rooms" => %{}}, name: :server)
  end

  def start(_, _) do
    {:ok, sup_pid} =
      Supervisor.start_link(
        [{Server, %{}}],
        strategy: :one_for_one
      )

    GenServer.call(:server, {:start}) |> IO.inspect()

    {:ok, sup_pid}
  end

  def stop(room_id) do
    GenServer.call(:server, {:leave, room_id})
  end

  defp send_create_room_message(socket_pid, negociator_pid) do
    request_id = UUID.uuid4()

    message = %Messages.CreateRoom{requestId: request_id} |> JSON.encode!()

    WebSockex.send_frame(socket_pid, {:text, message})

    send(negociator_pid, {:add_pending, request_id, self()})

    receive do
      {:resolved, %{"requestId" => _, "roomId" => room_id, "type" => _}} -> room_id
    end
  end

  defp send_leave_room_message(socket_pid, negociator_pid, room_id) do
    request_id = UUID.uuid4()

    message = %Messages.LeaveRoom{requestId: request_id, roomId: room_id} |> JSON.encode!()

    WebSockex.send_frame(socket_pid, {:text, message})

    send(negociator_pid, {:add_pending, request_id, self()})

    receive do
      {:resolved, %{"requestId" => _, "room" => room, "type" => _}} -> Map.get(room, "room_id")
    end
  end

  @impl true
  def handle_call({:start}, _from, state) do
    {:ok, negociator_pid, socket_pid} = SocketHandler.start_link(%{}, self())

    Supervisor.start_link(
      [
        {Registry, keys: :unique, name: Registry.UserNameRegistry},
        {ClientSupervisor, []}
      ],
      strategy: :one_for_one,
      name: Supervisor
    )

    send(self(), {:add_socket, socket_pid})

    room_id = send_create_room_message(socket_pid, negociator_pid)

    new_state =
      put_in(state, ["rooms", room_id], %{})
      |> Map.put("socket_pid", socket_pid)
      |> put_in(["socket_pids"], {negociator_pid, socket_pid, nil})

    {:reply, room_id, new_state}
  end

  @impl true
  def handle_call({:get_room_id}, _from, state) do
    room_id = get_in(state, ["rooms"]) |> Map.keys() |> Enum.at(0)

    {:reply, room_id, state}
  end

  @impl true
  def handle_call({:leave, room_id}, _from, state) do
    {negociator_pid, socket_pid, _} = get_in(state, ["socket_pids"])

    send_leave_room_message(socket_pid, negociator_pid, room_id)
    {:reply, room_id, state}
  end

  @impl true
  def handle_call({:get_room_members}, _from, state) do
    children = DynamicSupervisor.which_children(ClientSupervisor)
    {:reply, children, state}
  end

  @impl true
  def handle_info(
        {:sdp_offered, %{"sdpCert" => cert, "roomId" => room_id, "sourceUserId" => user_id}},
        state
      ) do
    ClientSupervisor.start_client("#{room_id}_#{user_id}")

    ClientHandler.start_connection(
      "#{room_id}_#{user_id}",
      room_id,
      user_id,
      cert,
      Map.get(state, "socket_pid")
    )

    {:noreply, state}
  end

  @impl true
  def handle_info(
        {:user_left,
         %{
           "roomId" => room_id,
           "userId" => user_id
         }},
        state
      ) do
    ClientHandler.close(room_id, user_id)

    {:noreply, state}
  end

  @impl true
  def handle_info(
        {:ice_candidate,
         %{
           "sourceUserId" => source_user_id,
           "sourceRoomId" => source_room_id,
           "ICECandidate" => ice_candidate
         }},
        state
      ) do
    ClientHandler.add_ice_certificate(
      "#{source_room_id}_#{source_user_id}",
      JSON.decode!(ice_candidate) |> ExWebRTC.ICECandidate.from_json()
    )

    {:noreply, state}
  end

  @impl true
  def handle_info(unknown, state) do
    Logger.debug("unknown message received #{inspect(unknown)}")

    {:noreply, state}
  end
end
