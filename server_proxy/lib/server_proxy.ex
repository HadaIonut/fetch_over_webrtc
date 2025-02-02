defmodule Server do
  use WebSockex
  require Logger

  def start() do
    {:ok, server_pid} = Task.start_link(fn -> loop(%{}) end)
    {:ok, negociator_pid} = Negociator.start_link(%{})

    {:ok, sock_pid} =
      SocketHandler.start_link(%{
        negociator_pid: negociator_pid,
        server_pid: server_pid,
        active_connections: %{}
      })

    send(server_pid, {:set_state, sock_pid, negociator_pid})

    send_create_room_message(sock_pid, negociator_pid)
  end

  def send_create_room_message(sock_pid, negociator_pid) do
    request_id = UUID.uuid4()

    val = JSON.encode!(%Messages.CreateRoom{requestId: request_id})

    send_message(sock_pid, negociator_pid, request_id, val)
  end

  @spec send_message(pid, pid, String.t(), String.t()) :: :ok
  defp send_message(sock_pid, negociator_pid, request_id, message) do
    Logger.info("Sending message: #{message}")

    WebSockex.send_frame(sock_pid, {:text, message})

    send(negociator_pid, {:add_pending, request_id, self()})

    receive do
      {:resolved, value} -> IO.inspect(value)
    end
  end

  defp loop(state) do
    receive do
      {:set_state, sock_pid, negociator_pid} ->
        loop(%{negociator_pid: negociator_pid, sock_pid: sock_pid})

      {:establish_connection, message} ->
        IO.inspect("sending establish message")
        WebSockex.send_frame(state.sock_pid, {:text, message})
        loop(state)
    end
  end
end

defmodule Client do
  use WebSockex

  alias ExWebRTC.{
    PeerConnection,
    SessionDescription
  }

  require Logger

  def start(room) do
    {:ok, negociator_pid} = Negociator.start_link(%{})
    {:ok, sock_pid} = SocketHandler.start_link(%{negociator_pid: negociator_pid, parent: self()})

    send_join_room_message(sock_pid, negociator_pid, room)
  end

  def send_join_room_message(sock_pid, negociator_pid, room_id) do
    request_id = UUID.uuid4()

    val = JSON.encode!(%Messages.JoinRoom{requestId: request_id, roomId: room_id})

    send_message(sock_pid, negociator_pid, request_id, val)

    {:ok, pc} =
      PeerConnection.start_link(ice_servers: [%{urls: "stun:stun.l.google.com:19302"}])

    {:ok, data_channel} = PeerConnection.create_data_channel(pc, "ligma")

    {:ok, offer} = PeerConnection.create_offer(pc)
    PeerConnection.set_local_description(pc, offer)

    request_id = UUID.uuid4()

    val =
      JSON.encode!(%Messages.Offer{
        requestId: request_id,
        roomId: room_id,
        sdpCert: offer |> SessionDescription.to_json() |> JSON.encode!()
      })

    send_message(sock_pid, negociator_pid, request_id, val)

    receive do
      {:answer, remote_sdp} ->
        sdp = remote_sdp |> JSON.decode!() |> ExWebRTC.SessionDescription.from_json()
        PeerConnection.set_remote_description(pc, sdp)
        IO.inspect("connection established")
    end
  end

  @spec send_message(pid, pid, String.t(), String.t()) :: :ok
  defp send_message(sock_pid, negociator_pid, request_id, message) do
    Logger.info("Sending message: #{message}")
    WebSockex.send_frame(sock_pid, {:text, message})

    send(negociator_pid, {:add_pending, request_id, self()})

    receive do
      {:resolved, value} -> IO.inspect(value)
    end
  end
end
