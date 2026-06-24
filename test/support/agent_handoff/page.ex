defmodule Dialup.AgentHandoffTest.Page do
  use Dialup.Page

  declare_action(
    name: :increment,
    desc: "Increment the shared counter",
    params: %{amount: {:integer, default: 1}}
  )

  declare_action(
    name: :reset,
    desc: "Reset the counter",
    params: %{},
    confirm: :human,
    agent_only: true
  )

  declare_region(
    name: :counter,
    role: "status",
    desc: "Shared counter value",
    data: :count,
    actions: [:increment]
  )

  def mount(_params, assigns), do: {:ok, Map.put(assigns, :count, 0)}

  def __available__(:increment, assigns), do: assigns.count < 10
  def __available__(:reset, _assigns), do: true
  def __available__(:navigate_root, assigns), do: assigns.count == 0
  def __available__(_action, _assigns), do: true

  def agent_state(assigns), do: %{count: assigns.count}

  def agent_message(_assigns) do
    %{
      concept: "A shared counter operated by a human and an agent.",
      flow: ["Read the scene", "Increment with the current version"]
    }
  end

  def handle_event(:increment, params, assigns) do
    amount = params["amount"] || params[:amount] || 1
    {:update, Map.update!(assigns, :count, &(&1 + amount))}
  end

  def handle_event(:reset, _params, assigns), do: {:update, Map.put(assigns, :count, 0)}

  def render(assigns) do
    ~H"""
    <.dialup_region name={:counter} role="status" desc="Shared counter value">
      <span>{@count}</span>
    </.dialup_region>
    <.dialup_action name={:increment} amount="1">Increment</.dialup_action>
    <.dialup_action navigate="/">Reload</.dialup_action>
    <.dialup_action navigate="/missing">Broken link</.dialup_action>
    """
  end
end
