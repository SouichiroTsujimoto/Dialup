defmodule Dialup.AvailableTest.Page do
  @moduledoc false
  use Dialup.Page

  def mount(_params, assigns), do: {:ok, Map.put(assigns, :count, 0)}

  def agent_state(assigns), do: %{count: assigns.count}

  def render(assigns) do
    ~H"""
    <.dialup_action
      name={:increment}
      desc="Increment"
      params={%{amount: :integer}}
      available={@count < 10}
      amount="1"
    >
      Increment
    </.dialup_action>
    """
  end
end
