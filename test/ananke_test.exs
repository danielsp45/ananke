defmodule AnankeTest do
  use ExUnit.Case
  doctest Ananke

  test "greets the world" do
    assert Ananke.hello() == :world
  end
end
