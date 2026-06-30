defmodule Dialup.AvailableTest.ModeConflictPage do
  @moduledoc false
  use Dialup.Page

  alias Dialup.CommandedTest.Ordering

  def render(assigns) do
    ~H"""
    <.dialup_action
      command={{Ordering, :increment}}
      set={%{sidebar_open: true}}
      desc="Conflicting modes"
      params={%{}}
    >
      Conflict
    </.dialup_action>
    """
  end
end
