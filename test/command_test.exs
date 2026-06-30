defmodule Dialup.CommandTest do
  use ExUnit.Case, async: true

  test "map_error uses static error metadata" do
    action = %{errors: %{too_many: "Too many increments"}}
    assert Dialup.Command.map_error(action, :too_many) == "Too many increments"
    assert Dialup.Command.map_error(action, :unknown) == "操作を完了できませんでした"
  end

  test "build merges bind values and request params" do
    defmodule Sample.Commands.Increment do
      defstruct [:amount, :base]
    end

    defmodule Sample do
      def dispatch(_), do: :ok
    end

    {:ok, command} =
      Dialup.Command.build(Sample, :increment, %{base: 1}, %{"amount" => 2})

    assert command.amount == 2
    assert command.base == 1
  end
end
