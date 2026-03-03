# Events

クライアント側のイベントをサーバーで処理する方法。

## イベントの流れ

```
ユーザー操作 → dialup.js → WebSocket → UserSessionProcess → handle_event/3
```

## HTML属性によるイベント定義

### ws-event

クリックなどの単純なイベント。

```html
<button ws-event="increment">+</button>
<button ws-event="like" ws-value="123">いいね</button>
```

```elixir
def handle_event("increment", "", assigns) do
  {:update, Map.update!(assigns, :count, &(&1 + 1))}
end

def handle_event("like", "123", assigns) do
  # ws-value の値が第2引数に入る
  {:noreply, assigns}
end
```

### ws-submit

フォーム送信。

```html
<form ws-submit="save">
  <input name="title" />
  <input name="body" />
  <button type="submit">保存</button>
</form>
```

```elixir
def handle_event("save", %{"title" => title, "body" => body}, assigns) do
  case Posts.create(title, body) do
    {:ok, post} -> 
      {:update, assigns |> overwrite(%{post: post, errors: []})}
    {:error, errors} ->
      {:update, assigns |> overwrite(%{errors: errors})}
  end
end
```

### ws-change

入力値のリアルタイム変更。

```html
<input type="text" ws-change="draft" value={@draft} />
<p id="draft-preview"></p>
```

```elixir
def handle_event("draft", value, assigns) do
  # :noreply で再描画しない（状態のみ保存）
  {:noreply, Map.put(assigns, :draft, value)}
end
```

`:noreply` を使うことで、キー入力のたびに再描画が発生しない。

### ws-href

クライアント側ナビゲーション。

```html
<a ws-href="/users/{@user.id}">プロフィール</a>
```

`ws-href` はイベントとしてサーバーに送られず、dialup.js が自動的に `__navigate` を送信する。

## イベント名の命名

- 動詞＋対象の形式: `"increment"`, `"delete_item"`, `"submit_form"`
- 一貫性を保つ（スネークケース推奨）

## サーバーサイドの応答パターン

### 即座のフィードバック（:patch）

頻繁に更新される部分のみ効率的に更新：

```elixir
defp render_counter(assigns) do
  ~H"""<span id="counter">{@count}</span>"""
end

def handle_event("inc", _value, assigns) do
  new_assigns = Map.update!(assigns, :count, &(&1 + 1))
  {:patch, "counter", render_counter(new_assigns), new_assigns}
end
```

### 遅延更新（:noreply + :update）

複数回の高速イベントをバッチ処理：

```elixir
def handle_event("selection_change", ids, assigns) do
  # 状態のみ更新、再描画はしない
  {:noreply, Map.put(assigns, :selected_ids, ids)}
end

def handle_event("confirm_selection", _value, assigns) do
  # ボタン押下時に一括で再描画
  {:update, assigns}
end
```

## エラーハンドリング

```elixir
def handle_event("risky_op", _value, assigns) do
  try do
    result = risky_operation()
    {:update, assigns |> overwrite(%{result: result})}
  rescue
    e ->
      # エラーを状態に記録
      {:update, assigns |> overwrite(%{error: Exception.message(e)})}
  end
end
```
