defmodule Dialup.AvailableDerivationTest do
  use ExUnit.Case, async: true

  alias Dialup.Agent
  alias Dialup.AvailableTest.DeclaredPage
  alias Dialup.AvailableTest.DefaultPage
  alias Dialup.AvailableTest.Page

  test "__available__/2 is generated from available={...}" do
    assert Page.__available__(:increment, %{count: 5}) == true
    assert Page.__available__(:increment, %{count: 10}) == false
    assert Page.__available__(:unknown, %{count: 0}) == true
  end

  test "__available__/2 is generated from declare_action available:" do
    assert DeclaredPage.__available__(:increment, %{count: 5}) == true
    assert DeclaredPage.__available__(:increment, %{count: 10}) == false
  end

  test "actions without available default to true when other actions derive predicates" do
    assert Page.__available__(:unknown, %{count: 99}) == true
  end

  test "pages without available expressions fall back to Agent.available?/3 default" do
    assert Agent.available?(DefaultPage, :noop, %{}) == true
    refute function_exported?(DefaultPage, :__available__, 2)
  end

  test "manual __available__/2 conflicts with available={...} at compile time" do
    assert_raise CompileError, ~r/__available__\/2 manually/, fn ->
      Code.compile_file("test/fixtures/available_conflict_page.ex")
    end
  end

  test "command and set modes are mutually exclusive at compile time" do
    assert_raise CompileError, ~r/modes are exclusive/, fn ->
      Code.compile_file("test/fixtures/mode_conflict_page.ex")
    end
  end
end
