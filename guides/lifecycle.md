# Lifecycle

ページのライフサイクル（mount → render → handle_event）について。

## ライフサイクル概要

```
初回アクセス: HTTP → mount/2 → render/1 → WebSocket接続 → mount/2
イベント発生:            ← handle_event/3 → render/1
ページ遷移:              ← mount/2（新ページ）→ render/1
```

## Mount

### mount/2（動的ページ用）

```elixir
def mount(params, assigns) :: {:ok, map()}
```

- `params`: URLパラメータ（動的ルート時）または空マップ
- `assigns`: 親レイアウトから引き継がれた状態
- 戻り値: `{:ok, new_assigns}` で初期状態を設定

```elixir
def mount(params, assigns) do
  # 動的パラメータの処理
  id = params["id"]
  item = id && Items.get(id)
  
  assigns
  |> set_default(%{count: 0, loaded: false})  # デフォルト値の設定
  |> overwrite(%{item: item, loaded: true})   # 値を上書き
end
```

### mount/1（静的ページ用）

```elixir
def mount(assigns) :: {:ok, map()}
```

paramsが不要なページで使用。`mount/2` が自動生成される。

```elixir
def mount(assigns) do
  {:ok, assigns |> set_default(%{count: 0})}
end
```

### mountの呼び出しタイミング

| タイミング | 備考 |
|-----------|------|
| 初回HTTPリクエスト | SSR用に一度呼ばれる |
| WebSocket接続確立後 | セッション初期化時 |
| ページ遷移時 | 新しいページのモジュールで呼ばれる |
| 再接続時 | プロセスが生存していれば呼ばれない |

## Render

```elixir
def render(assigns) :: Phoenix.LiveView.Rendered.t()
```

HTMLを生成。`assigns` の現在値を使ってレンダリング。

```elixir
def render(assigns) do
  ~H"""
  <div>
    <p>Count: {@count}</p>
    <%= if @loaded do %>
      <p>Loaded!</p>
    <% end %>
  </div>
  """
end
```

### レンダリングのタイミング

- mount直後
- handle_eventで `{:update, _}` または `{:patch, _, _, _}` を返した後

## Handle Event

```elixir
def handle_event(event :: String.t(), value :: any(), assigns :: map()) ::
  {:noreply, map()} | {:update, map()} | {:patch, String.t(), any(), map()}
```

### 返り値の種類

| 返り値 | 動作 |
|-------|------|
| `{:noreply, assigns}` | 状態のみ更新、再描画なし |
| `{:update, assigns}` | 全体を再描画 |
| `{:patch, target_id, html, assigns}` | 指定IDの要素のみ更新 |

```elixir
# 状態のみ更新（リアルタイム入力同期など）
def handle_event("draft", value, assigns) do
  {:noreply, Map.put(assigns, :draft, value)}
end

# 全体再描画
def handle_event("submit", _value, assigns) do
  {:update, Map.put(assigns, :submitted, true)}
end

# 部分更新（効率的）
defp render_counter(assigns) do
  ~H"""<span id="counter">{@count}</span>"""
end

def handle_event("inc", _value, assigns) do
  new_assigns = Map.update!(assigns, :count, &(&1 + 1))
  {:patch, "counter", render_counter(new_assigns), new_assigns}
end
```

## 状態の継続と破棄

### ページ遷移時の状態

```
/users/123 → /users/123/edit
```

- `/users` レイアウトの state: **継続**
- `[id]` ページの state: **継続**
- 新しいページの state: **新規作成**

```
/users/123 → /items/456
```

- `/users` レイアウトの state: **破棄**
- `/items` レイアウトの state: **新規作成**

### 注意点

- 親レイアウトの変更は子ページに反映される
- プロセスクラッシュ時はmountから再開
- 永続化が必要なデータはDBに保存
