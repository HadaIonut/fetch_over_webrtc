defmodule UUIDTools do
  def binary_to_uuid(<<_::binary-size(16)>> = bin) do
    hex = Base.encode16(bin, case: :lower)

    String.slice(hex, 0, 8) <>
      "-" <>
      String.slice(hex, 8, 4) <>
      "-" <>
      String.slice(hex, 12, 4) <>
      "-" <>
      String.slice(hex, 16, 4) <>
      "-" <>
      String.slice(hex, 20, 12)
  end

  def uuid_to_binary(uuid) do
    IO.inspect("rec uuid #{uuid}")

    out =
      String.replace(uuid, "-", "") |> Base.decode16!(case: :lower)

    IO.inspect("enc uuid #{out}")
    IO.inspect("enc + dec uuid #{binary_to_uuid(out)}")

    out
  end
end
