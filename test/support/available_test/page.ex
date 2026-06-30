defmodule Dialup.AvailableTest.Page do
  @moduledoc false
  use Dialup.Page

  def mount(_params, assigns), do: {:ok, Map.put(assigns, :count, 0)}

  def handle_event("increment", %{"amount" => amount}, assigns) do
    amount = if is_integer(amount), do: amount, else: String.to_integer(to_string(amount))
    {:update, Map.update!(assigns, :count, &(&1 + amount))}
  end

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
