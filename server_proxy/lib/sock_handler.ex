defmodule Negociator do
  require Logger

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

  @reply_message_types ["offer", "join", "create"]

  def start_link(state) do
    WebSockex.start_link("ws://localhost:3000/ws", __MODULE__, state)
  end

  def handle_connect(_conn, state) do
    Logger.info("Connected!")
    {:ok, state}
  end

  def handle_frame({:text, msg}, state) do
    Logger.info("Received Message: #{msg}")

    case JSON.decode(msg) do
      {:ok, %{"type" => type} = res} when type in @reply_message_types ->
        send(
          state.negociator_pid,
          {:resolve_request, Map.get(res, "requestId"), res}
        )

        IO.inspect(state)
        {:ok, state}

      {:ok, %{"type" => type}} when type == "userJoined" ->
        Logger.info("someone joined the room")
        IO.inspect(state)
        {:ok, state}

      {:ok, %{"type" => type, "sdpCert" => cert}} when type == "userOfferReply" ->
        Logger.info("answer received")

        send(state.parent, {:answer, cert})

        {:ok, state}

      {:ok,
       %{"type" => type, "sdpCert" => cert, "sourceUserId" => source_user_id, "roomId" => room_id}}
      when type == "userOffer" ->
        Logger.info("someone offered a cert")

        establish_connection_with_user(source_user_id, room_id, cert, state.server_pid)

        {:ok, state}

      {:ok, msg} ->
        Logger.info("unknown message received")
        IO.inspect(msg)
        {:ok, state}

      {:error, err} ->
        IO.inspect(err)
        {:ok, state}
    end
  end

  defp establish_connection_with_user(user, room_id, sdp_cert, server_pid) do
    {:ok, pc} =
      ExWebRTC.PeerConnection.start_link(ice_servers: [%{urls: "stun:stun.l.google.com:19302"}])

    cert = sdp_cert |> JSON.decode!() |> ExWebRTC.SessionDescription.from_json()
    ExWebRTC.PeerConnection.set_remote_description(pc, cert)

    {:ok, answer} = ExWebRTC.PeerConnection.create_answer(pc)
    ExWebRTC.PeerConnection.set_local_description(pc, answer)
    request_id = UUID.uuid4()

    message =
      JSON.encode!(%Messages.OfferReply{
        requestId: request_id,
        roomId: room_id,
        toUser: user,
        sdpCert: answer |> ExWebRTC.SessionDescription.to_json() |> JSON.encode!()
      })

    send(server_pid, {
      :establish_connection,
      message
    })
  end

  def handle_disconnect(%{reason: {:local, reason}}, state) do
    Logger.info("Local close with reason: #{inspect(reason)}")
    {:ok, state}
  end

  def handle_disconnect(disconnect_map, state) do
    super(disconnect_map, state)
  end
end
