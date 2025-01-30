defmodule ServerProxyTest do
  use ExUnit.Case
  doctest ServerProxy

  test "greets the world" do
    assert ServerProxy.hello() == :world
  end
end
