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

## handle_info — サーバー起点のイベント

クライアントからのイベントではなく、プロセスメッセージを受け取る場合に使用する。

### PubSub の購読

`subscribe/2` を使うとナビゲーション時の自動 unsubscribe が有効になる。

```elixir
def mount(_params, assigns) do
  subscribe(MyApp.PubSub, "notifications")  # 自動 unsubscribe 付き
  {:ok, %{notifications: []}}
end

def handle_info({:notification, msg}, assigns) do
  {:update, Map.update!(assigns, :notifications, &[msg | &1])}
end
```

別ページに遷移すると、フレームワークが自動的に `"notifications"` を unsubscribe する。`Phoenix.PubSub.subscribe/2` を直接呼ぶとこの自動管理は行われない。

### タイマー

```elixir
def mount(_params, assigns) do
  Process.send_after(self(), :tick, 1_000)
  {:ok, %{count: 0}}
end

def handle_info(:tick, assigns) do
  Process.send_after(self(), :tick, 1_000)
  {:update, Map.update!(assigns, :count, &(&1 + 1))}
end
```

`handle_info/2` を定義しない場合はデフォルト実装（`:noreply`）が自動生成される。

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

### JavaScriptフック（:push_event）

DOMモーフィング以外のJS操作が必要なときに使用する。サーバーが名前付きイベントとペイロードをクライアントに送り、`Dialup.connect` に登録したハンドラを呼び出す。

**サーバー側**

```elixir
def handle_event("save", params, assigns) do
  {:ok, item} = Items.create(params)
  {:push_event, "show_toast", %{message: "保存しました"}, Map.put(assigns, :item, item)}
end
```

返り値: `{:push_event, event_name, payload, assigns}`

- `event_name` — クライアント側のハンドラ名（文字列）
- `payload` — クライアントに渡すデータ（マップ）
- `assigns` — 更新後の assigns（同時に全体再描画も行われる）

**クライアント側**

```html
<script>
Dialup.connect({
  hooks: {
    show_toast: ({ message }) => {
      document.getElementById("toast").textContent = message;
    },
    open_modal: ({ id }) => {
      document.getElementById(id).showModal();
    },
    scroll_to_top: () => {
      window.scrollTo({ top: 0, behavior: "smooth" });
    }
  }
});
</script>
```

フックは HTML の morph 適用後に呼ばれるため、更新済みの DOM にアクセスできる。フックが登録されていないイベント名は無視される。

**`handle_info` からも使用可能**

```elixir
def handle_info({:notification, msg}, assigns) do
  {:push_event, "show_toast", %{message: msg}, assigns}
end
```

### リダイレクト（:redirect）

イベント処理後に別URLへ遷移させる。session は保持したまま、新しいページの `mount/2` が呼ばれる。

```elixir
def handle_event("logout", _value, assigns) do
  {:redirect, "/login", assigns}
end

def handle_event("create", params, assigns) do
  case Posts.create(params) do
    {:ok, post} ->
      {:redirect, "/posts/#{post.id}", assigns}
    {:error, errors} ->
      {:update, Map.put(assigns, :errors, errors)}
  end
end
```

クライアント側の URL も自動的に更新される（`history.pushState`）。

## エラーハンドリング

`mount`・`handle_event`・`handle_info` の中で例外が発生しても GenServer はクラッシュしない。フレームワークが自動的に例外をキャッチし、エラー画面をブラウザに送信して元の state を維持する。

```
例外発生 → エラー画面をブラウザに表示 → プロセスは生存 → 次のイベントを受け付け可能
```

エラーを UI に表示したい場合は、自分で rescue して assigns に記録する：

```elixir
def handle_event("risky_op", _value, assigns) do
  case risky_operation() do
    {:ok, result} -> {:update, assigns |> overwrite(%{result: result})}
    {:error, msg} -> {:update, assigns |> overwrite(%{error: msg})}
  end
end
```
