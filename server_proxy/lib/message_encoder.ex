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
        acc <> Atom.to_string(val) <> "=" <> Map.fetch!(headers, val) <> ", "
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
  end

  defmodule Body do
    defmodule AppJsonBody do
    end

    defmodule MultiPartBody do
      defstruct [:TextContent, :Files]

      defmodule File do
        defstruct [:FileName, :FileType, :FileContent]
      end
    end

    def encode_body(body, "application/json") do
      JSON.encode!(body)
    end

    def encode_body(
          %MultiPartBody{TextContent: text_content, Files: files},
          "multipart/form-data"
        ) do
      textPart =
        "------------------------------------------------\n" <>
          JSON.encode!(text_content) <>
          "\n------------------------------------------------\n"

      filesPart =
        Enum.reduce(files, "", fn %MultiPartBody.File{
                                    FileName: file_name,
                                    FileType: file_type,
                                    FileContent: file_content
                                  },
                                  acc ->
          acc <>
            "------------------------------------------------" <>
            "\nFileName:" <>
            file_name <>
            "\nFileType:" <>
            file_type <>
            "\n" <>
            Base.encode64(file_content) <>
            "\n------------------------------------------------"
        end)

      textPart <> filesPart
    end
  end
end

defmodule MessageEncoder do
  @part_size 100_000
  @version 1

  def test() do
    header = %Message.Header{
      RequestType: "GET",
      Route: "/ligma",
      RequestHeaders: %{header1: "myInteligentValue", header2: "myOtherInteligentValue"},
      ContentType: "multipart/form-data"
    }

    f1 = File.read!("protocol")

    file = %Message.Body.MultiPartBody.File{
      FileName: "protocol",
      FileType: "text",
      FileContent: f1
    }

    body = %Message.Body.MultiPartBody{
      TextContent: "fjdsklfjdsklfjsdakl",
      Files: [file, file, file, file, file, file, file, file, file, file, file, file]
    }

    encoded = encode_message(header, body)
  end

  def encode_message(header, body) do
    text = get_text_content(header, body)

    req_type = Map.get(header, :RequestType) |> Message.Header.request_type_to_int()

    parts_count = ceil(bit_size(text) / @part_size)
    parts = BitUtils.chunks(text, @part_size)

    id = UUID.uuid4()

    Enum.with_index(parts)
    |> Enum.map(fn {part, index} ->
      bit_head = <<@version::4, parts_count::16, index::16, req_type::4>> <> id
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
    headerText =
      "\nRoute: " <>
        route <>
        "\nRequestHeaders: " <>
        Message.Header.encode_request_headers(request_headers) <>
        "\nContentType: " <> content_type <> "\n"

    bodyText =
      "\r\n" <> Message.Body.encode_body(body, content_type) <> "\r\n"

    headerText <> bodyText
  end
end
