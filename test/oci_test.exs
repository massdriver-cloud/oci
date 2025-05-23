defmodule OCITest do
  use ExUnit.Case
  doctest OCI

  test "greets the world" do
    assert OCI.hello() == :world
  end
end
