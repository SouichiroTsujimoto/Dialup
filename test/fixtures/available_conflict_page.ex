defmodule Dialup.AvailableTest.ConflictPage do
  use Dialup.Page

  def __available__(:increment, _assigns), do: true

  def render(assigns) do
    ~H"""
    <.dialup_action
      name={:increment}
      desc="Increment"
      params={%{}}
      available={assigns.count < 10}
    >
      Increment
    </.dialup_action>
    """
  end
end
