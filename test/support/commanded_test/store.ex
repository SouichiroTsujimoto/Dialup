defmodule Dialup.CommandedTest.Store do
  @moduledoc false
  use Agent

  def start_link(initial \\ %{count: 0}) do
    Agent.start_link(fn -> initial end, name: __MODULE__)
  end

  def get, do: Agent.get(__MODULE__, & &1)

  def increment(amount) do
    Agent.update(__MODULE__, fn state -> %{state | count: state.count + amount} end)
  end

  def reset do
    Agent.update(__MODULE__, fn _ -> %{count: 0} end)
  end
end
