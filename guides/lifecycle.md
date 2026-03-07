# Lifecycle

ページのライフサイクル（mount → render → handle_event/handle_info）について。

## ライフサイクル概要

```
初回接続:   WebSocket接続 → layout.mount/1（session確定）→ page.mount/2（assigns確定）→ render
ページ遷移: __navigate → page.mount/2（assigns リセット）→ render
イベント:   handle_event/3 → {:update, _} なら render
再接続:     プロセス生存中なら mount なしで現在の state で再描画
```

## layout.mount/1

```elixir
def mount(session :: map()) :: {:ok, map()}
```

WebSocket接続時に一度だけ呼ばれる。ページ遷移では再呼び出しされない。

- `session`: 親レイアウトが設定した session（最上位レイアウトは `%{}` を受け取る）
- 戻り値: `{:ok, new_session}` で session に追加するキーを返す

```elixir
defmodule MyApp.App.Layout do
  use Dialup.Layout

  def mount(session) do
    user = Repo.get(User, get_user_id_from_cookie())
    {:ok, Map.put(session, :current_user, user)}
  end

  def render(assigns) do
    ~H"""
    <nav>{@current_user.name}</nav>
    <main>{raw(@inner_content)}</main>
    """
  end
end
```

`mount/1` を定義しない場合はデフォルト実装（session をそのまま返す）が使われる。

## page.mount/2

```elixir
def mount(params :: map(), assigns :: map()) :: {:ok, map()}
```

ナビゲーションのたびに呼ばれる。assigns は毎回リセットされてから再設定される。

- `params`: URLパラメータ（パスパラメータ＋クエリパラメータ）
- `assigns`: session の内容（`current_user` 等を参照可能）
- 戻り値: `{:ok, new_assigns}` — 返したマップがそのまま page assigns になる

```elixir
def mount(%{"id" => id}, assigns) do
  post = Posts.get!(id, assigns.current_user)
  {:ok, %{post: post}}
end
```

### mount/1（静的ページ用）

params が不要なページでは `mount/1` を定義できる。`mount/2` は自動生成される。

```elixir
def mount(assigns) do
  {:ok, %{items: Items.all()}}
end
```

### mount の呼び出しタイミング

| タイミング | layout.mount | page.mount |
|-----------|:---:|:---:|
| 初回 WebSocket 接続 | 呼ばれる | 呼ばれる |
| ページ遷移（ws-href） | 呼ばれない | 呼ばれる |
| 再接続（プロセス生存中） | 呼ばれない | 呼ばれない |
| 再接続（タイムアウト済み） | 呼ばれる | 呼ばれる |

## handle_event/3

```elixir
def handle_event(event :: String.t(), value :: any(), assigns :: map()) ::
  {:noreply, map()} | {:update, map()} |
  {:patch, String.t(), any(), map()} | {:redirect, String.t(), map()}
```

`assigns` には `session + assigns + params` がマージされた状態が渡される。

### 返り値

| 返り値 | 動作 |
|-------|------|
| `{:noreply, assigns}` | 状態のみ更新、再描画なし |
| `{:update, assigns}` | 全体を再描画 |
| `{:patch, target_id, html, assigns}` | 指定IDの要素のみ更新 |
| `{:redirect, path, assigns}` | 別URLへ遷移（session保持、assigns リセット） |

```elixir
# 再描画なし（頻繁なイベントに）
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

# 別ページへリダイレクト
def handle_event("logout", _value, assigns) do
  {:redirect, "/login", Map.delete(assigns, :current_user)}
end
```

## handle_info/2

```elixir
def handle_info(msg :: any(), assigns :: map()) ::
  {:noreply, map()} | {:update, map()} |
  {:patch, String.t(), any(), map()} | {:redirect, String.t(), map()}
```

`Process.send_after/3` や `Phoenix.PubSub` などからのメッセージを受け取る。返り値は `handle_event/3` と同じ。

```elixir
def mount(_params, assigns) do
  # 5秒ごとにリフレッシュ
  Process.send_after(self(), :refresh, 5_000)
  {:ok, %{data: Data.fetch()}}
end

def handle_info(:refresh, assigns) do
  Process.send_after(self(), :refresh, 5_000)
  {:update, Map.put(assigns, :data, Data.fetch())}
end
```

```elixir
def mount(_params, assigns) do
  # subscribe/2 を使うとナビゲーション時に自動 unsubscribe される
  subscribe(MyApp.PubSub, "room:lobby")
  {:ok, %{messages: []}}
end

def handle_info({:new_message, msg}, assigns) do
  {:update, Map.update!(assigns, :messages, &[msg | &1])}
end
```

`subscribe/2` で登録したトピックは別ページへのナビゲーション時にフレームワークが自動的に unsubscribe する。`handle_info/2` を定義しない場合はデフォルト実装（`:noreply`）が使われる。

## エラー時の挙動

`mount`・`handle_event`・`handle_info` の中で例外が発生した場合：

- GenServer はクラッシュせず、プロセスは生存し続ける
- エラー内容（メッセージ＋スタックトレース）をブラウザに表示する
- `handle_event` / `handle_info` のエラーは元の state に戻す（assigns は変化しない）
- `mount` のエラーはページが未確定のまま待機状態になる

## render/1

```elixir
def render(assigns) :: Phoenix.LiveView.Rendered.t()
```

`assigns` の現在値を使ってHTMLを生成する。`~H` シジルまたは `.html.heex` ファイルを使用。

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

**注意**: `~H` はローカル変数を直接参照できない（HEExのchange tracking制約）。必ず `assigns` を引数に取る関数内で使用し、`@field_name` でアクセスすること。
