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

  defp start_connection(%{"sdpCert" => cert, "roomId" => room_id, "sourceUserId" => user_id}) do
    {:ok, pc} =
      ExWebRTC.PeerConnection.start(ice_servers: [%{urls: "stun:stun.l.google.com:19302"}])

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
      {:start, callback_pid} ->
        {:ok, negociator_pid, socket_pid} = SocketHandler.start_link(%{}, self())
        {:ok, proxy_pid} = ServerProxy.start(self())

        send(self(), {:add_socket, socket_pid})

        room_id = send_create_room_message(socket_pid, negociator_pid)
        send(callback_pid, {:room_started, room_id})

        put_in(state, ["rooms", room_id], %{})
        |> put_in(["proxy_pid"], proxy_pid)
        |> put_in(["socket_pids"], {negociator_pid, socket_pid, proxy_pid})
        |> loop()

      {:leave, callback_pid, room_id} ->
        {negociator_pid, socket_pid, _} = get_in(state, ["socket_pids"])

        send_leave_room_message(socket_pid, negociator_pid, room_id)
        send(callback_pid, {:room_stopped, room_id})

      {:user_joined, %{"roomId" => room_id, "members" => members}} ->
        new_users =
          Enum.filter(members, fn %{"id" => mem_id} ->
            get_in(state, ["rooms", room_id, mem_id]) == nil
          end)
          |> Enum.map(fn %{"id" => elem} -> elem end)

        update_in(state, ["rooms", room_id], fn room_data ->
          Enum.reduce(new_users, room_data, fn elem, acc ->
            Map.put(acc, elem, [])
          end)
        end)
        |> loop()

      {:get_room_members, callback_pid, room_id} ->
        members = get_in(state, ["rooms", room_id])

        send(callback_pid, {:members_response, members})

        loop(state)

      {:user_left, %{"roomId" => room_id, "members" => members}} ->
        members = Enum.map(members, fn %{"id" => mem_id} -> mem_id end)

        to_remove =
          get_in(state, ["rooms", room_id])
          |> Map.keys()
          |> Enum.filter(fn key -> !Enum.member?(members, key) end)

        Enum.reduce(to_remove, to_remove, fn elem, acc ->
          [peer_connection, pid | _rest] = get_in(state, ["rooms", room_id, elem])
          Process.exit(peer_connection, :kill)
          Process.exit(pid, :kill)

          [peer_connection] ++ acc
        end)
        |> Enum.reduce(state, fn elem, acc ->
          case elem do
            val when is_pid(val) ->
              {_, new_data} = pop_in(acc, [val])
              new_data

            val ->
              {_, new_data} = pop_in(acc, ["rooms", room_id, val])
              new_data
          end
        end)
        |> loop()

      {:sdp_offered, data} ->
        {message, room_id, user_id, peer_connection} = start_connection(data)
        Map.get(state, "socket_pid") |> WebSockex.send_frame({:text, message})

        {:ok, pid} = WebRTCHandler.start(peer_connection, room_id, user_id, self())

        # bullshit mapping pc -> pid at global root because i have no other way to identify who is who without it
        Map.put(state, peer_connection, pid)
        |> put_in(["rooms", room_id, user_id], [peer_connection, pid])
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

        [pc, _] = get_in(state, ["rooms", source_room_id, source_user_id])

        ExWebRTC.PeerConnection.add_ice_candidate(pc, ice_candidate)

        loop(state)

      {:send_message, msg} ->
        Map.get(state, "socket_pid") |> WebSockex.send_frame({:text, msg})
        loop(state)

      {:ex_webrtc, pc, msg} ->
        try do
          Map.get(state, pc)
          |> send(msg)
        rescue
          e in ArgumentError -> IO.inspect(e)
        end

        loop(state)

      {:WebRTCDecoded, room_id, user_id, "pong", "pong"} ->
        [pc, _, data_channel] = get_in(state, ["rooms", room_id, user_id])

        ExWebRTC.PeerConnection.send_data(pc, data_channel, "pong")

        loop(state)

      {:WebRTCDecoded, room_id, user_id, request_id, msg} ->
        [pc, _, data_channel] = get_in(state, ["rooms", room_id, user_id])

        Map.get(state, "proxy_pid")
        |> send({:relay, msg, request_id, pc, data_channel})

        loop(state)

      {:opened_data_channel, room_id, user_id, data_channel} ->
        update_in(state, ["rooms", room_id, user_id], fn [pc, pid] -> [pc, pid, data_channel] end)
        |> loop()

      unknown ->
        IO.inspect("unknown message received #{inspect(unknown)}")
        loop(state)
    end
  end
end
