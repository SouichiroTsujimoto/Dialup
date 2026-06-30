defmodule Dialup.CommandedTest.Ordering do
  @moduledoc false
  alias Dialup.CommandedTest.Ordering.Commands.Increment
  alias Dialup.CommandedTest.Store

  def dispatch(%Increment{} = command, _opts \\ []) do
    Store.increment(command.amount)
    :ok
  end
end
