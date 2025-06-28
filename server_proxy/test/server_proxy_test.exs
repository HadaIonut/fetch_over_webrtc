defmodule ServerProxyTest do
  use ExUnit.Case, async: true
  doctest ServerProxy

  test "Server starts & stops" do
    {server_pid, room_id} = Server.start()

    assert(server_pid != nil)
    assert(room_id != nil)

    assert(Process.alive?(server_pid))

    Server.stop(server_pid, room_id)
  end

  test "Client can join & leave the server" do
    {server_pid, room_id} = Server.start()
    {client_pid, msg} = Client.join(room_id)

    assert(msg, "connection established")

    send(server_pid, {:get_room_members, self(), room_id})

    receive do
      {:members_response, members} ->
        mem_keys = Map.keys(members)
        assert(length(mem_keys) == 2)
    end

    Client.leave(client_pid, room_id)
    Server.stop(server_pid, room_id)
  end

  test "Clinet can ping the server" do
    {server_pid, room_id} = Server.start()
    {client_pid, msg} = Client.join(room_id)

    send(client_pid, {:ping_server})

    receive do
      {:WebRTCDecoded, request_id, message} ->
        assert(request_id == "pong")
        assert(message == "pong")
    end

    Client.leave(client_pid, room_id)
    Server.stop(server_pid, room_id)
  end

  test "Client can send json to the server, have it relayed and response sent back" do
    {server_pid, room_id} = Server.start()
    {client_pid, msg} = Client.join(room_id)

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

    send(client_pid, {:send_message, header, body, request_id})

    receive do
      {:WebRTCDecoded, ^request_id, {rec_header, rec_body}} ->
        assert(rec_header == header)
        assert(rec_body == body)
    end

    Client.leave(client_pid, room_id)
    Server.stop(server_pid, room_id)
  end

  test "Client can send get request to the server, have it relayed and response sent back" do
    {server_pid, room_id} = Server.start()
    {client_pid, msg} = Client.join(room_id)

    header = %Message.Header{
      RequestType: "GET",
      Route: "http://localhost:8080/ping",
      RequestHeaders: %{}
    }

    body = %{}

    request_id = UUID.uuid4()

    send(client_pid, {:send_message, header, body, request_id})

    receive do
      {:WebRTCDecoded, ^request_id, {_rec_header, rec_body}} ->
        assert(
          %{
            "message" => "pong"
          } == rec_body
        )
    end

    Client.leave(client_pid, room_id)
    Server.stop(server_pid, room_id)
  end

  test "Client can send file to the server, have it relayed and response sent back" do
    {server_pid, room_id} = Server.start()
    {client_pid, msg} = Client.join(room_id)

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

    send(client_pid, {:send_message, header, body, request_id})

    receive do
      {:WebRTCDecoded, ^request_id, {_rec_header, rec_body}} ->
        assert(
          rec_body ==
            "Fetch Over WebRTC protocol message:\n\n0     4       20      36     40             328\n----------------------------------------------\n| Vers|Total   |Current| Req |  Request Id   |\n|\tion\t|Parts   |Part   | type|  UUIDv4       |\n----------------------------------------------\n|\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t |\n|\t\t\t\t\t\tHeader + Body\t\t\t\t\t\t\t\t\t\t |\n|\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t |\n----------------------------------------------\n\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t100_328\n\n\nRoute:\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t\\n\nRequestHeaders: name=value, name2=value2, ... \\n\nContentType:\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t\\n\n\n\\r\\n\n\napplication/json:\n\t- body in json format\nmultipart/form-data:\n----\nText (maybe json)\n----\n----\nFileName:\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t\\n\nFileType:\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t\\n\n-----Content in base64-----\t\t\t\t\t\t\t\t\t\t\\n\n----\n\n\nRequest Types:\n\nGET    == 0\nPOST   == 1\nPUT    == 2\nDELETE == 3\n\n"
        )
    end

    Client.leave(client_pid, room_id)
    Server.stop(server_pid, room_id)
  end
end
