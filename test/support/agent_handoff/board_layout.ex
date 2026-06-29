defmodule Dialup.AgentHandoffTest.BoardLayout do
  use Dialup.Layout

  def mount(session) do
    {:ok, set_default(session, %{board_label: "empty"})}
  end

  def render(assigns) do
    ~H"""
    {raw(@inner_content)}
    """
  end
end
