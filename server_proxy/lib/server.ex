defmodule Server do
  require Logger

  def start() do
    {:ok, parent_pid} = Task.start_link(fn -> loop(%{}) end)
    {:ok, negociator_pid, socket_pid} = SocketHandler.start_link(%{}, parent_pid)

    send(parent_pid, {:add_socket, socket_pid})

    send_create_room_message(socket_pid, negociator_pid)
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

  defp loop(state) do
    receive do
      {:sdp_offered, %{"sdpCert" => cert, "roomId" => room_id, "sourceUserId" => user_id}} ->
        {:ok, pc} =
          ExWebRTC.PeerConnection.start_link(
            ice_servers: [%{urls: "stun:stun.l.google.com:19302"}]
          )

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

        Map.get(state, "socket_pid") |> WebSockex.send_frame({:text, message})

        loop(state)

      # code
      {:add_socket, socket_pid} ->
        Map.put(state, "socket_pid", socket_pid) |> loop()
    end
  end
end
