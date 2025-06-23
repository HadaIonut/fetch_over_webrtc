defmodule ClientManager do
  def start(room_id) do
    Client.start(room_id)
  end

  def send_test_message(client_pid) do
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

    send_message(client_pid, header, body)
  end

  defp send_message(client_pid, header, body) do
    request_id = UUID.uuid4()

    send(client_pid, {:send_message, header, body, request_id})

    receive do
      {:WebRTCDecoded, ^request_id, message} ->
        message
    end
  end
end
