defmodule Collector do
  def receive_n(n) when n > 0 do
    receive_n(n, [])
  end

  defp receive_n(0, acc) do
    Enum.reverse(acc)
  end

  defp receive_n(n, acc) do
    receive do
      msg ->
        receive_n(n - 1, [msg | acc])
    end
  end
end
