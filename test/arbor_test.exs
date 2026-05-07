defmodule ArborTest do
  use ExUnit.Case
  doctest Arbor

  test "greets the world" do
    assert Arbor.hello() == :world
  end
end
