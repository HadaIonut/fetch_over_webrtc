defmodule Server do
  require Logger

  def start() do
    {:ok, parent_pid} = Task.start_link(fn -> loop(%{}) end)

    send(parent_pid, {:start})
  end

  defp send_create_room_message(socket_pid, negociator_pid) do
    request_id = UUID.uuid4()

    message = %Messages.CreateRoom{requestId: request_id} |> JSON.encode!()

    Logger.info("Sending message: #{message}")

    WebSockex.send_frame(socket_pid, {:text, message})

    send(negociator_pid, {:add_pending, request_id, self()})

    receive do
      {:resolved, value} -> IO.inspect(value)
    end
  end

  defp start_connection(%{"sdpCert" => cert, "roomId" => room_id, "sourceUserId" => user_id}) do
    {:ok, pc} =
      ExWebRTC.PeerConnection.start_link(ice_servers: [%{urls: "stun:stun.l.google.com:19302"}])

    cert = cert |> JSON.decode!() |> ExWebRTC.SessionDescription.from_json()
    ExWebRTC.PeerConnection.set_remote_description(pc, cert)

    {:ok, answer} = ExWebRTC.PeerConnection.create_answer(pc)
    ExWebRTC.PeerConnection.set_local_description(pc, answer)
    request_id = UUID.uuid4()

    JSON.encode!(%Messages.OfferReply{
      requestId: request_id,
      roomId: room_id,
      toUser: user_id,
      sdpCert: answer |> ExWebRTC.SessionDescription.to_json() |> JSON.encode!()
    })
  end

  defp loop(state) do
    receive do
      {:start} ->
        {:ok, negociator_pid, socket_pid} = SocketHandler.start_link(%{}, self())

        send(self(), {:add_socket, socket_pid})

        send_create_room_message(socket_pid, negociator_pid)

        loop(state)

      {:sdp_offered, data} ->
        message = start_connection(data)
        Map.get(state, "socket_pid") |> WebSockex.send_frame({:text, message})

        loop(state)

      {:add_socket, socket_pid} ->
        Map.put(state, "socket_pid", socket_pid) |> loop()
    end
  end
end
