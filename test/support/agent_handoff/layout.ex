defmodule Dialup.AgentHandoffTest.Layout do
  use Dialup.Layout

  def render(assigns) do
    ~H"""
    <nav>
      <.dialup_action navigate="/board">Board</.dialup_action>
    </nav>
    {raw(@inner_content)}
    """
  end
end
