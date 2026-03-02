defmodule Dialup.App.Root do
  use Dialup.Page

  def render(assigns) do
    ~H"""
    <div class="container">
      <div class="card">
        <h2>Hello Dialup</h2>
        <p>this is home page.</p>
        <a ws-href="/about">About</a>
      </div>
    </div>
    """
  end
end
