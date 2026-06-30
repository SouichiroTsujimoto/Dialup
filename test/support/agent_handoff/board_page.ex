defmodule Dialup.AgentHandoffTest.BoardPage do
  use Dialup.Page

  declare_action(
    name: :set_board_label,
    desc: "Update the persisted board label",
    params: %{value: :string}
  )

  def mount(_params, assigns), do: {:ok, assigns}

  def agent_state(assigns), do: %{board_label: assigns.board_label}

  def handle_event(:set_board_label, params, assigns) do
    value = params["value"] || params[:value] || ""
    {:update, overwrite(assigns, %{board_label: to_string(value)})}
  end

  def render(assigns) do
    ~H"""
    <h1 data-board-label>{@board_label}</h1>
    <.dialup_action name={:set_board_label} value="kept">Set kept</.dialup_action>
    """
  end
end
