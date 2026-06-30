defmodule Dialup.AvailableTest.DeclaredPage do
  @moduledoc false
  use Dialup.Page

  declare_action(
    name: :increment,
    desc: "Increment the counter",
    params: %{amount: :integer},
    available: quote(do: assigns.count < 10)
  )

  def mount(_params, assigns), do: {:ok, Map.put(assigns, :count, 0)}

  def agent_state(assigns), do: %{count: assigns.count}

  def render(assigns) do
    ~H"""
    <.dialup_action name={:increment} amount="1">Increment</.dialup_action>
    """
  end
end
