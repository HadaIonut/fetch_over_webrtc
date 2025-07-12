defmodule ServerProxyTest do
  use ExUnit.Case, async: true
  doctest ServerProxy

  setup_all do
    {:ok, room_id: GenServer.call(:server, {:get_room_id})}
  end

  test "Client can join & leave the server", state do
    {client_pid, msg} = Client.join(state[:room_id])

    assert(msg, "connection established")

    members = GenServer.call(:server, {:get_room_members})

    assert(length(members) == 1)

    Client.leave(client_pid, state[:room_id])
  end

  test "Clinet can ping the server", state do
    {client_pid, _msg} = Client.join(state[:room_id])

    GenServer.cast(client_pid, {:ping_server})

    receive do
      {:WebRTCDecoded, request_id, message} ->
        assert(request_id == "pong")
        assert(message == "pong")
    end

    Client.leave(client_pid, state[:room_id])
  end

  test "Multiple Clinets can ping the server", state do
    {client_pid, _msg} = Client.join(state[:room_id])
    {client_pid_2, _msg} = Client.join(state[:room_id])
    {client_pid_3, _msg} = Client.join(state[:room_id])

    GenServer.cast(client_pid, {:ping_server})
    GenServer.cast(client_pid_2, {:ping_server})
    GenServer.cast(client_pid_3, {:ping_server})

    receive do
      {:WebRTCDecoded, request_id, message} ->
        assert(request_id == "pong")
        assert(message == "pong")
    end

    receive do
      {:WebRTCDecoded, request_id, message} ->
        assert(request_id == "pong")
        assert(message == "pong")
    end

    receive do
      {:WebRTCDecoded, request_id, message} ->
        assert(request_id == "pong")
        assert(message == "pong")
    end

    Client.leave(client_pid, state[:room_id])
  end

  test "Client can send json to the server, have it relayed and response sent back", state do
    {client_pid, _msg} = Client.join(state[:room_id])

    header = %Message.Header{
      RequestType: "POST",
      Route: "http://localhost:8080/echo",
      RequestHeaders: %{},
      ContentType: "application/json"
    }

    body = %{
      "a" => "a",
      "b" => "b"
    }

    request_id = UUID.uuid4()

    GenServer.call(client_pid, {:send_message, header, body, request_id})

    receive do
      {:WebRTCDecoded, ^request_id, {rec_header, rec_body}} ->
        assert(rec_header == header)
        assert(rec_body == body)
    end

    Client.leave(client_pid, state[:room_id])
  end

  test "Client can send get request to the server, have it relayed and response sent back",
       state do
    {client_pid, _msg} = Client.join(state[:room_id])

    header = %Message.Header{
      RequestType: "GET",
      Route: "http://localhost:8080/ping",
      RequestHeaders: %{}
    }

    body = %{}

    request_id = UUID.uuid4()

    GenServer.call(client_pid, {:send_message, header, body, request_id})

    receive do
      {:WebRTCDecoded, ^request_id, {_rec_header, rec_body}} ->
        assert(
          %{
            "message" => "pong"
          } == rec_body
        )
    end

    Client.leave(client_pid, state[:room_id])
  end

  test "Client can send file to the server, have it relayed and response sent back", state do
    {client_pid, _msg} = Client.join(state[:room_id])

    header = %Message.Header{
      RequestType: "POST",
      Route: "http://localhost:8080/upload",
      RequestHeaders: %{},
      ContentType: "multipart/form-data"
    }

    f1 = File.read!("protocol")

    file = %Message.Body.MultiPartBody.File{
      FileName: "protocol",
      FileType: "text",
      FileContent: f1
    }

    body = %Message.Body.MultiPartBody{
      TextContent: %{
        "description" => "fjsklafjdslka"
      },
      Files: [file]
    }

    request_id = UUID.uuid4()

    GenServer.call(client_pid, {:send_message, header, body, request_id})

    receive do
      {:WebRTCDecoded, ^request_id, {_rec_header, rec_body}} ->
        assert(
          rec_body ==
            "Fetch Over WebRTC protocol message:\n\n0     4       20      36     40             168\n----------------------------------------------\n| Vers|Total   |Current| Req |  Request Id   |\n|\tion\t|Parts   |Part   | type|  UUIDv4       |\n----------------------------------------------\n|\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t |\n|\t\t\t\t\t\tHeader + Body\t\t\t\t\t\t\t\t\t\t |\n|\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t |\n----------------------------------------------\n\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t100_328\n\n\nRoute:\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t\\n\nRequestHeaders: name=value, name2=value2, ... \\n\nContentType:\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t\\n\n\n\\r\\n\n\napplication/json:\n\t- body in json format\nmultipart/form-data:\n----\nText (maybe json)\n----\n----\nFileName:\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t\\n\nFileType:\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t\\n\n-----Content in base64-----\t\t\t\t\t\t\t\t\t\t\\n\n----\n\n\nRequest Types:\n\nGET    == 0\nPOST   == 1\nPUT    == 2\nDELETE == 3\n\n"
        )
    end

    Client.leave(client_pid, state[:room_id])
  end

  def run(counter, _request_id_1, _request_id_2, _header_1, _body_1, _header_2, _body_2)
      when counter == 2 do
  end

  def run(counter, request_id_1, request_id_2, header_1, body_1, header_2, body_2)
      when counter < 2 do
    receive do
      {:WebRTCDecoded, ^request_id_1, {rec_header, rec_body}} ->
        assert(rec_header == header_1)
        assert(rec_body == body_1)
        run(counter + 1, request_id_1, request_id_2, header_1, body_1, header_2, body_2)

      {:WebRTCDecoded, ^request_id_2, {rec_header, rec_body}} ->
        assert(rec_header == header_2)
        assert(rec_body == body_2)

        run(counter + 1, request_id_1, request_id_2, header_1, body_1, header_2, body_2)
    after
      # executed after 250 milliseconds
      250 -> run(counter, request_id_1, request_id_2, header_1, body_1, header_2, body_2)
    end
  end

  test "Multile clients can send messages", state do
    {client_pid, _msg} = Client.join(state[:room_id])
    {client_pid_2, _msg} = Client.join(state[:room_id])

    header_1 = %Message.Header{
      RequestType: "POST",
      Route: "http://localhost:8080/echo",
      RequestHeaders: %{},
      ContentType: "application/json"
    }

    body_1 = %{
      "a" => "a",
      "b" => "b"
    }

    request_id_1 = UUID.uuid4()

    GenServer.call(client_pid, {:send_message, header_1, body_1, request_id_1})

    header_2 = %Message.Header{
      RequestType: "POST",
      Route: "http://localhost:8080/echo",
      RequestHeaders: %{},
      ContentType: "application/json"
    }

    body_2 = %{
      "c" => "c",
      "d" => "d"
    }

    request_id_2 = UUID.uuid4()

    GenServer.call(client_pid_2, {:send_message, header_2, body_2, request_id_2})

    run(0, request_id_1, request_id_2, header_1, body_1, header_2, body_2)

    Client.leave(client_pid, state[:room_id])
  end
end
