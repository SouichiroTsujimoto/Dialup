defmodule Dialup.AvailableTest.DefaultPage do
  @moduledoc false
  use Dialup.Page

  def mount(_params, assigns), do: {:ok, assigns}

  def render(assigns) do
    ~H"""
    <.dialup_action name={:noop} desc="No-op action" params={%{}}>
      No-op
    </.dialup_action>
    """
  end
end
