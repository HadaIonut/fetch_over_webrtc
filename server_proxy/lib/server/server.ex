defmodule Server do
  require Logger

  def start() do
    {:ok, loop_pid} = Task.start_link(fn -> loop(%{"rooms" => %{}}) end)

    send(loop_pid, {:start, self()})

    receive do
      {:room_started, room_id} -> {loop_pid, room_id}
    end
  end

  def stop(loop_pid, room_id) do
    send(loop_pid, {:leave, self(), room_id})

    receive do
      {:room_stopped, room_id} -> {loop_pid, room_id}
    end
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

  defp loop(state) do
    receive do
      {:start, callback_pid} ->
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
        send(callback_pid, {:room_started, room_id})

        put_in(state, ["rooms", room_id], %{})
        |> Map.put("socket_pid", socket_pid)
        |> put_in(["socket_pids"], {negociator_pid, socket_pid, nil})
        |> loop()

      {:leave, callback_pid, room_id} ->
        {negociator_pid, socket_pid, _} = get_in(state, ["socket_pids"])

        send_leave_room_message(socket_pid, negociator_pid, room_id)
        send(callback_pid, {:room_stopped, room_id})

      {:get_room_members, callback_pid, room_id} ->
        members = get_in(state, ["rooms", room_id])

        send(callback_pid, {:members_response, members})

        loop(state)

      {:sdp_offered, %{"sdpCert" => cert, "roomId" => room_id, "sourceUserId" => user_id}} ->
        ClientSupervisor.start_client("#{room_id}_#{user_id}")

        ClientHandler.start_connection(
          "#{room_id}_#{user_id}",
          room_id,
          user_id,
          cert,
          Map.get(state, "socket_pid")
        )

        loop(state)

      {:ice_candidate,
       %{
         "sourceUserId" => source_user_id,
         "sourceRoomId" => source_room_id,
         "ICECandidate" => ice_candidate
       }} ->
        ClientHandler.add_ice_certificate(
          "#{source_room_id}_#{source_user_id}",
          JSON.decode!(ice_candidate) |> ExWebRTC.ICECandidate.from_json()
        )

        loop(state)

      unknown ->
        Logger.debug("unknown message received #{inspect(unknown)}")
        loop(state)
    end
  end
end
