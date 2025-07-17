defmodule HtmlEncoder do
  def random_string() do
    for _ <- 1..10, into: "", do: <<Enum.random(~c'0123456789abcdef')>>
  end

  def encode(message, request_id, peer_connection, data_channel) do
    appearances =
      Regex.scan(~r/src="(.*?)"/, message)
      |> Enum.reduce(%{}, fn [_, match], acc ->
        Map.put(acc, match, random_string())
      end)

    replaced =
      Regex.replace(~r/src="(.*?)"/, message, fn _, match ->
        frag_id = Map.get(appearances, match)
        replace_text = "__url_replace_#{frag_id}__"

        Task.start(fn ->
          img = Req.get!(match).body |> Base.encode64()

          encoded =
            WebRTCMessageEncoder.encode_message(
              :frag,
              img,
              request_id,
              frag_id
            )

          Enum.each(encoded, fn part ->
            ExWebRTC.PeerConnection.send_data(peer_connection, data_channel, part, :binary)
          end)
        end)

        "src=\"#{replace_text}\""
      end)

    "#{replaced}\n---frags---\n "
  end
end
