defmodule Dialup.CommandedTest.App do
  @moduledoc false
  alias Dialup.CommandedTest.Page

  def page_for("/"), do: Page
  def page_for(_path), do: nil
  def path_params(_path), do: %{}
  def layouts_for(_path), do: []
  def error_page_for(_path), do: nil

  def dispatch("/", assigns), do: {:ok, Page.render(assigns) |> render_html()}

  def dispatch(_path, _assigns), do: {:error, :not_found}

  def __session_store__, do: :memory

  def __shell_opts__, do: %{title: "Commanded Test", lang: "en"}

  def __render_shell__(assigns) do
    "<html><body>#{assigns.inner_content}</body></html>"
  end

  defp render_html(rendered) do
    rendered
    |> Phoenix.HTML.Safe.to_iodata()
    |> IO.iodata_to_binary()
  end
end
