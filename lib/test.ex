defmodule Dialup.Test do
  @moduledoc """
  ページの mount / イベント / レンダリングを GenServer や WebSocket を起動せずに
  直接テストするためのヘルパー。
  """

  @doc """
  ページを mount して `{assigns, rendered_html}` を返す。

      {assigns, html} = Dialup.Test.mount_page(MyApp.App.Page)
      assert assigns.count == 0
  """
  def mount_page(page_module, params \\ %{}, session \\ %{}) do
    {:ok, assigns} = page_module.mount(params, session)
    html = render(page_module, assigns)
    {assigns, html}
  end

  @doc """
  handle_event を呼び出して `{result_tuple, rendered_html}` を返す。

      {{:patch, "counter", _rendered, new_assigns}, _html} =
        Dialup.Test.send_event(MyApp.App.Page, "increment", "", assigns)
  """
  def send_event(page_module, event, value, assigns) do
    result = page_module.handle_event(event, value, assigns)
    result_assigns = extract_assigns(result)
    html = render(page_module, result_assigns)
    {result, html}
  end

  @doc """
  handle_info を呼び出して `{result_tuple, rendered_html}` を返す。
  """
  def send_info(page_module, msg, assigns) do
    result = page_module.handle_info(msg, assigns)
    result_assigns = extract_assigns(result)
    html = render(page_module, result_assigns)
    {result, html}
  end

  @doc """
  assigns を渡して HTML 文字列を返す。
  """
  def render(page_module, assigns) do
    page_module.render(assigns)
    |> Phoenix.HTML.Safe.to_iodata()
    |> IO.iodata_to_binary()
  end

  defp extract_assigns({:noreply, assigns}), do: assigns
  defp extract_assigns({:update, assigns}), do: assigns
  defp extract_assigns({:patch, _target, _rendered, assigns}), do: assigns
  defp extract_assigns({:redirect, _path, assigns}), do: assigns
  defp extract_assigns({:push_event, _event, _payload, assigns}), do: assigns
end
