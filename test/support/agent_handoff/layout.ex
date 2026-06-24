defmodule Dialup.AgentHandoffTest.Layout do
  use Dialup.Layout

  def render(assigns) do
    ~H"""
    <nav>
      <.dialup_action navigate="/board">Board</.dialup_action>
      <.dialup_action navigate="/board" confirm={:human} name={:navigate_board_human}>
        Board (human confirm)
      </.dialup_action>
    </nav>
    {raw(@inner_content)}
    """
  end
end
