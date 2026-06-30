defmodule Dialup.CommandedTest.Page do
  @moduledoc false
  use Dialup.Page

  alias Dialup.CommandedTest.Ordering
  alias Dialup.CommandedTest.Store

  def mount(_params, assigns) do
    count = Store.get().count

    {:ok,
     assigns
     |> set_default(%{count: count, sidebar_open: false, errors: []})}
  end

  def agent_state(assigns), do: %{count: assigns.count, sidebar_open: assigns.sidebar_open}

  def render(assigns) do
    ~H"""
    <span data-test="count">{@count}</span>

    <.dialup_action
      command={{Ordering, :increment}}
      desc="Increment the counter"
      params={%{amount: :integer}}
      bind={%{}}
      errors={%{too_many: "Too many increments"}}
      available={@count < 10}
    >
      Increment
    </.dialup_action>

    <.dialup_action
      name={:toggle_sidebar}
      desc="Toggle the sidebar"
      params={%{}}
      set={%{sidebar_open: !@sidebar_open}}
    >
      Toggle sidebar
    </.dialup_action>
    """
  end
end
