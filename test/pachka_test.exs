defmodule PachkaTest do
  use ExUnit.Case
  doctest Pachka

  test "greets the world" do
    assert Pachka.hello() == :world
  end
end
