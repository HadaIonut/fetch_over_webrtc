defmodule HtmlEncoder do
  def random_string() do
    for _ <- 1..10, into: "", do: <<Enum.random(~c'0123456789abcdef')>>
  end

  def encode(route, message, request_id, peer_connection, data_channel) do
    appearances =
      Regex.scan(~r/(?:(?:src)|(?:href))="(.*?)"/, message)
      |> Enum.reduce(%{}, fn [_, match], acc ->
        Map.put(acc, match, :crypto.hash(:sha, match) |> Base.encode64() |> binary_part(0, 10))
      end)

    replaced =
      Regex.replace(~r/(?:(?:src)|(?:href))="(.*?)"/, message, fn _, match ->
        frag_id = Map.get(appearances, match)
        replace_text = "__url_replace_#{frag_id}__"

        Task.start(fn ->
          url =
            case String.starts_with?(match, "http") do
              true -> match
              false -> "#{route}#{match}"
            end

          try do
            res = Req.get!(url)
            content_type = res.headers["content-type"]
            body = res.body
            img = body |> Base.encode64()

            encoded =
              WebRTCMessageEncoder.encode_message(
                :frag,
                "data:#{content_type};base64,#{img}",
                request_id,
                frag_id
              )

            Enum.each(encoded, fn part ->
              ExWebRTC.PeerConnection.send_data(peer_connection, data_channel, part, :binary)
            end)
          rescue
            error -> raise "this url is being stupid #{url}, #{error}"
          end
        end)

        "WebRTCSrc=\"#{replace_text}\""
      end)

    "#{replaced}\n---frags---\n "
  end
end
