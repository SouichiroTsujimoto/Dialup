defmodule Dialup.AvailableDerivationTest do
  use ExUnit.Case, async: true

  alias Dialup.AvailableTest.Page

  test "__available__/2 is generated from available={...}" do
    assert Page.__available__(:increment, %{count: 5}) == true
    assert Page.__available__(:increment, %{count: 10}) == false
    assert Page.__available__(:unknown, %{}) == true
  end

  test "manual __available__/2 conflicts with available={...} at compile time" do
    assert_raise CompileError, ~r/__available__\/2 manually/, fn ->
      Code.compile_file("test/fixtures/available_conflict_page.ex")
    end
  end
end
