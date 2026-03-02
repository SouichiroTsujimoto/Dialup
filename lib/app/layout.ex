defmodule Dialup.App.Layout do
  use Dialup.Layout

  def render(assigns) do
    ~H"""
    <div id="app-layout">
      <header>
        <nav>
          <a ws-href="/">Home</a>
          <a ws-href="/about">About</a>
        </nav>
      </header>
      <main>
        {raw(assigns[:inner_content])}
      </main>
      <footer>
        <p>Dialup Framework</p>
      </footer>
    </div>
    """
  end
end
