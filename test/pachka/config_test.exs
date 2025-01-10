defmodule Pachka.ConfigTest do
  use ExUnit.Case, async: true

  test "schema/0 returns NimbleOptions schema" do
    assert is_struct(Pachka.Config.schema(), NimbleOptions)
  end
end
