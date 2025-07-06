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
    String.replace(uuid, "-", "") |> Base.decode16!(case: :mixed)
  end
end
