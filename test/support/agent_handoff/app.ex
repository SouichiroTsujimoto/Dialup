defmodule Dialup.AgentHandoffTest.App do
  alias Dialup.AgentHandoffTest.BoardPage
  alias Dialup.AgentHandoffTest.Layout
  alias Dialup.AgentHandoffTest.Page

  def page_for("/"), do: Page
  def page_for("/board"), do: BoardPage
  def page_for(_path), do: nil
  def path_params(_path), do: %{}
  def layouts_for("/"), do: [Layout]
  def layouts_for("/board"), do: [Layout]
  def layouts_for(_path), do: []
  def error_page_for(_path), do: nil

  def dispatch("/", assigns),
    do: {:ok, Dialup.Router.render_with_layouts(Page, [Layout], assigns)}

  def dispatch("/board", assigns),
    do: {:ok, Dialup.Router.render_with_layouts(BoardPage, [Layout], assigns)}

  def dispatch(_path, _assigns), do: {:error, :not_found}
  def __session_store__, do: :memory
  def __shell_opts__, do: %{title: "Test", lang: "en"}

  def __render_shell__(assigns) do
    "<html><head><title>Test</title></head><body>#{assigns.inner_content}</body></html>"
  end
end
