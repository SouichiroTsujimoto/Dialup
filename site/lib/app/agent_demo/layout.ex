defmodule Dialup.App.AgentDemo.Layout do
  use Dialup.Layout

  def mount(session) do
    {:ok,
     set_default(session, %{
       project: "社内勉強会の企画",
       tasks: [],
       next_id: 1,
       handoff: nil
     })}
  end

  def render(assigns) do
    ~H"""
    {raw(@inner_content)}
    """
  end
end
