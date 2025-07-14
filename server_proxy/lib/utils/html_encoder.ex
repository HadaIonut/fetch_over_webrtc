defmodule HtmlEncoder do
  def random_string() do
    for _ <- 1..10, into: "", do: <<Enum.random(~c'0123456789abcdef')>>
  end

  def encode(message) do
    proxy_pid = self()

    appearances = Regex.scan(~r/src="(.*?)"/, message) |> Enum.count()

    replaced =
      Regex.replace(~r/src="(.*?)"/, message, fn _, match ->
        replace_text = "__url_replace_#{random_string()}__"

        Task.start(fn ->
          img = Req.get!(match).body |> Base.encode64()

          send(proxy_pid, "---#{replace_text}---\n#{img}\n")
        end)

        "src=\"#{replace_text}\""
      end)

    "#{replaced}\n---frags---\n#{Collector.receive_n(appearances) |> Enum.join("")}"
  end
end
