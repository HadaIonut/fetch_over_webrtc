defmodule BitUtils do
  def chunks(binary, n) do
    do_chunks(binary, n, [])
  end

  defp do_chunks(binary, n, acc) when bit_size(binary) <= n do
    Enum.reverse([binary | acc])
  end

  defp do_chunks(binary, n, acc) do
    <<chunk::size(n), rest::bitstring>> = binary
    do_chunks(rest, n, [<<chunk::size(n)>> | acc])
  end
end

defmodule Message do
  defmodule Header do
    defstruct [:RequestType, :Route, :RequestHeaders, :ContentType]

    def encode_request_headers(headers) do
      Map.keys(headers)
      |> Enum.reduce("", fn val, acc ->
        acc <> val <> "=" <> Map.fetch!(headers, val) <> ", "
      end)
      |> String.trim_trailing(", ")
    end

    def request_type_to_int(val) do
      case val do
        "GET" -> 0
        "POST" -> 1
        "PUT" -> 2
        "DELETE" -> 3
      end
    end

    def request_int_to_type(val) do
      case val do
        0 -> "GET"
        1 -> "POST"
        2 -> "PUT"
        3 -> "DELETE"
      end
    end
  end

  defmodule Body do
    @text_encoding_types ["text/plain", "text/html", "text/css", "text/javascript", "text/csv"]
    defmodule MultiPartBody do
      defstruct [:TextContent, :Files]

      defmodule File do
        defstruct [:FileName, :FileType, :FileContent]
      end
    end

    def encode_body(body, encoding_type)
        when is_binary(body)
        when encoding_type in @text_encoding_types do
      body
    end

    def encode_body(body, "application/json") do
      JSON.encode!(body)
    end

    def encode_body(%{}, "") do
      ""
    end

    def encode_body("", "") do
      ""
    end

    def encode_body(
          %MultiPartBody{TextContent: text_content, Files: files},
          "multipart/form-data"
        ) do
      textPart =
        "----\n" <>
          JSON.encode!(text_content) <>
          "\n----\n"

      filesPart =
        Enum.reduce(files, "", fn
          %MultiPartBody.File{
            FileName: file_name,
            FileType: file_type,
            FileContent: file_content
          },
          acc ->
            acc <>
              "----" <>
              "\nFileName:" <>
              file_name <>
              "\nFileType:" <>
              file_type <>
              "\n" <>
              Base.encode64(file_content) <>
              "\n----\n"
        end)

      textPart <> filesPart
    end
  end
end

defmodule WebRTCMessageDecoder do
  require Logger
  alias Message.Body.MultiPartBody
  @current_version 1
  @text_encoding_types ["text/plain", "text/html", "text/css", "text/javascript", "text/csv"]

  use GenServer

  @impl true
  def init({callback_pid, room_id, user_id}) do
    {:ok, %{callback_pid: callback_pid, room_id: room_id, user_id: user_id}}
  end

  @impl true
  def handle_cast(
        {:receive_message,
         <<version::4, parts_count::16, index::16, req_type::4, id::binary-size(16),
           rest::binary>>},
        state
      )
      when version == @current_version do
    id = UUIDTools.binary_to_uuid(id)
    Logger.debug("recieved something #{id} #{index}/#{parts_count}")

    new_state =
      Map.update(
        state,
        id,
        PriorityQueue.new() |> PriorityQueue.put({index, rest}),
        fn list ->
          list |> PriorityQueue.put({index, rest})
        end
      )

    cur_entry = Map.get(new_state, id)

    new_state =
      case cur_entry |> PriorityQueue.size() do
        ^parts_count ->
          msg =
            PriorityQueue.to_list(cur_entry)
            |> Enum.reduce("", fn {_, val}, acc -> acc <> val end)

          decoded = decode(msg, req_type)

          Map.get(state, :callback_pid)
          |> send(
            {:WebRTCDecoded, Map.get(state, :room_id), Map.get(state, :user_id), id, decoded}
          )

          Map.delete(new_state, id)

        _ ->
          new_state
      end

    {:noreply, new_state}
  end

  @impl true
  def handle_cast(
        {:receive_message, <<version::4, _rest::binary>>},
        state
      )
      when version != @current_version do
    {:noreply, state}
  end

  defp decode_request_headers(req_headers) do
    case String.length(req_headers) do
      0 ->
        %{}

      _ ->
        String.split(req_headers, ", ")
        |> Enum.reduce(%{}, fn entry, acc ->
          [key, value] = String.split(entry, "=")

          Map.put(acc, key, value)
        end)
    end
  end

  defp decode_body(body, encoding_type)
       when encoding_type in @text_encoding_types do
    body
  end

  defp decode_body("", "") do
    ""
  end

  defp decode_body(body, "application/json") do
    JSON.decode!(body)
  end

  defp decode_body(body, "multipart/form-data") do
    [text | files] =
      Regex.scan(~r/----\n(.*?)\n----/ms, body)
      |> Enum.map(fn res ->
        Enum.at(res, 1)
      end)

    %MultiPartBody{
      TextContent: JSON.decode!(text),
      Files:
        Enum.reduce(files, [], fn cur, acc ->
          [file_name, file_type, file_content] = String.split(cur, "\n")
          [_, file_name] = String.split(file_name, "FileName:")
          [_, file_type] = String.split(file_type, "FileType:")

          [
            %MultiPartBody.File{
              FileName: file_name,
              FileType: file_type,
              FileContent: Base.decode64!(file_content)
            }
            | acc
          ]
        end)
    }
  end

  defp decode(msg, req_type) do
    [header, body] = String.split(msg, "\r\n")

    [route, req_headers, content_type] =
      header |> String.split("\n")

    [_, route] = String.split(route, "Route: ")
    [_, req_headers] = String.split(req_headers, "RequestHeaders: ")
    req_headers = decode_request_headers(req_headers)
    [_, content_type] = String.split(content_type, "ContentType: ")

    body = decode_body(body, content_type)

    {%Message.Header{
       RequestType: Message.Header.request_int_to_type(req_type),
       Route: route,
       RequestHeaders: req_headers,
       ContentType: content_type
     }, body}
  end
end

defmodule WebRTCMessageEncoder do
  # 12500 bytes
  @part_size 100_000
  @version 1

  def encode_message(header, body, id \\ UUID.uuid4()) do
    text = get_text_content(header, body)

    req_type = Map.get(header, :RequestType) |> Message.Header.request_type_to_int()

    parts_count = ceil(bit_size(text) / @part_size)
    parts = BitUtils.chunks(text, @part_size)

    Enum.with_index(parts)
    |> Enum.map(fn {part, index} ->
      bit_head =
        <<@version::4, parts_count::16, index::16, req_type::4,
          UUIDTools.uuid_to_binary(id)::binary-size(16)>>

      bit_head <> part
    end)
  end

  defp get_text_content(
         %Message.Header{
           Route: route,
           RequestHeaders: request_headers,
           ContentType: content_type
         },
         body
       ) do
    content_type =
      case content_type do
        nil -> ""
        content_type -> content_type
      end

    headerText =
      "Route: " <>
        route <>
        "\nRequestHeaders: " <>
        Message.Header.encode_request_headers(request_headers) <>
        "\nContentType: " <> content_type <> "\r\n"

    bodyText =
      Message.Body.encode_body(body, content_type)

    headerText <> bodyText
  end
end
