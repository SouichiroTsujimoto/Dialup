defmodule Dialup.App.Root do
  use Dialup.Page

  def mount(assigns) do
    {:ok,
     Map.merge(assigns, %{
       count: 0,
       # ws-submit デモ用
       name: "",
       submitted_name: nil,
       # ws-change デモ用
       draft: ""
     })}
  end

  # --- カウンター ---

  def handle_event("increment", _value, assigns) do
    new_assigns = Map.update(assigns, :count, 1, &(&1 + 1))
    {:patch, "count", render_count(new_assigns), new_assigns}
  end

  def handle_event("decrement", _value, assigns) do
    new_assigns = Map.update(assigns, :count, -1, &(&1 - 1))
    {:patch, "count", render_count(new_assigns), new_assigns}
  end

  # --- ws-submit: フォーム送信 ---

  def handle_event("submit_name", %{"name" => name}, assigns) do
    new_assigns = %{assigns | name: name, submitted_name: name}
    {:update, new_assigns}
  end

  # --- ws-change: リアルタイム入力同期 ---

  def handle_event("draft_change", value, assigns) do
    # 入力のたびに呼ばれるが :noreply なので再描画しない（状態だけ保存）
    new_assigns = %{assigns | draft: value}
    {:patch, "draft", render_draft(new_assigns), new_assigns}
  end

  def handle_event("submit_draft", _value, assigns) do
    # ボタンを押したときだけ再描画
    {:update, %{assigns | submitted_name: assigns.draft, draft: ""}}
  end

  # --- private renders ---

  defp render_count(assigns) do
    ~H"""
    <p id="count">count: <%= assigns[:count] %></p>
    """
  end

  defp render_draft(assigns) do
    ~H"""
    <p id="draft"><%= assigns[:draft] %></p>
    """
  end

  def render(assigns) do
    ~H"""
    <h2>Hello Dialup</h2>
    <p>this is home page.</p>
    <a ws-href="/about">About</a>

    <hr />
    <h3>カウンター（:patch）</h3>
    <button ws-event="increment">+</button>
    <button ws-event="decrement">-</button>
    <p id="count">count: <%= assigns[:count] %></p>

    <hr />
    <h3>ws-submit デモ</h3>
    <form ws-submit="submit_name">
      <input type="text" name="name" value={assigns[:name]} placeholder="名前を入力" />
      <button type="submit">送信</button>
    </form>
    <%= if assigns[:submitted_name] do %>
      <p>送信された名前: <strong><%= assigns[:submitted_name] %></strong></p>
    <% end %>

    <hr />
    <h3>ws-change デモ（入力中にサーバー同期、ボタンで反映）</h3>
    <input type="text" ws-change="draft_change" value={assigns[:draft]} placeholder="入力中..." />
    <button ws-event="submit_draft">確定</button>
    <p id="draft"></p>
    <%= if assigns[:submitted_name] do %>
      <p>確定された値: <strong><%= assigns[:submitted_name] %></strong></p>
    <% end %>
    """
  end
end
