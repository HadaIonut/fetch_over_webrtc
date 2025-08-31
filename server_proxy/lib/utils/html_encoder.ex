defmodule HtmlEncoder do
  require Logger

  def random_string() do
    for _ <- 1..10, into: "", do: <<Enum.random(~c'0123456789abcdef')>>
  end

  defp get_url(match, route) do
    case String.starts_with?(match, "http") do
      true -> match
      false -> "#{route}#{match}"
    end
  end

  defp create_response_payload(url, res, request_id, frag_id) do
    content_type = res.headers["content-type"]

    body =
      case Enum.at(content_type, 0) |> String.contains?("javascript") do
        true ->
          {out, 0} =
            System.cmd("node", [
              "lib/javascript_inliner/main.js",
              URI.encode(url)
            ])

          out

        false ->
          res.body
      end

    img = body |> Base.encode64()

    WebRTCMessageEncoder.encode_message(
      :frag,
      "data:#{content_type};base64,#{img}",
      request_id,
      frag_id
    )
  end

  defp get_resource(match, route, request_id, frag_id, peer_connection, data_channel) do
    url = get_url(match, route)

    try do
      res = Req.get!(url)
      encoded = create_response_payload(url, res, request_id, frag_id)

      Enum.each(encoded, fn part ->
        ExWebRTC.PeerConnection.send_data(peer_connection, data_channel, part, :binary)
      end)
    rescue
      error -> IO.inspect("this url is being stupid #{url}")
    end
  end

  def encode(route, message, request_id, peer_connection, data_channel) do
    appearances =
      Regex.scan(~r/(?:(?:src)|(?:href)|(?:srcset))="(.*?)"/, message)
      |> Enum.reduce(%{}, fn [_, match], acc ->
        Map.put(acc, match, :crypto.hash(:sha, match) |> Base.encode64() |> binary_part(0, 10))
      end)

    replaced =
      Regex.replace(~r/(?:(?:src)|(?:href)|(?:srcset))="(.*?)"/, message, fn _, match ->
        frag_id = Map.get(appearances, match)
        replace_text = "__url_replace_#{frag_id}__"

        Task.start(fn ->
          get_resource(match, route, request_id, frag_id, peer_connection, data_channel)
        end)

        "WebRTCSrc=\"#{replace_text}\""
      end)

    "#{replaced}\n---frags---\n "
  end
end
