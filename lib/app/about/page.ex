defmodule Dialup.App.About do
  use Dialup.Page

  def render(assigns) do
    ~H"""
    <div class="container">
      <div class="card">
        <h2>Hello Dialup</h2>
        <p>this is about page.</p>
        <a ws-href="/">← Back to home</a>
      </div>
    </div>
    """
  end
end
