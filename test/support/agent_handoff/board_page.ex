defmodule Dialup.AgentHandoffTest.BoardPage do
  use Dialup.Page

  def mount(_params, assigns), do: {:ok, assigns}

  def render(assigns) do
    ~H"""
    <h1>Board</h1>
    """
  end
end
