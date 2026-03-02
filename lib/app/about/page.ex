defmodule Dialup.App.About do
  use Dialup.Page

  def mount(assigns) do
    {:ok, Map.put(assigns, :count, 0)}
  end

  def handle_event("increment", _value, assigns) do
    {:update, Map.update(assigns, :count, 1, &(&1 + 1))}
  end

  def handle_event("decrement", _value, assigns) do
    {:update, Map.update(assigns, :count, -1, &(&1 - 1))}
  end

  def render(assigns) do
    ~H"""
    <h2>Hello Dialup</h2>
    <p>this is about page.</p>
    <a ws-href="/">← Back to home</a>
    <button ws-event="increment">+</button>
    <button ws-event="decrement">-</button>
    <p>count: <%= assigns[:count] %></p>
    """
  end
end
