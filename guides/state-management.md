# State Management

Dialupの状態管理は `session`、`assigns`、`params` の3つに分かれている。

## 3種類の状態

| フィールド | 設定者 | ライフサイクル |
|-----------|--------|----------------|
| `session` | `layout.mount/1` | WebSocketセッション全体で持続 |
| `assigns` | `page.mount/2` | ナビゲーションごとにリセット |
| `params` | フレームワーク自動 | ナビゲーションごとに更新 |

### session

`layout.mount/1` が設定する。ページ遷移をまたいで持続するため、ログインユーザー情報などを格納する。

```elixir
defmodule MyApp.App.Layout do
  use Dialup.Layout

  def mount(session) do
    user = Repo.get(User, get_user_id_from_cookie())
    {:ok, Map.put(session, :current_user, user)}
  end
end
```

レイアウトがネストしている場合、親レイアウトの結果が子レイアウトの `mount/1` に渡される。

### assigns

`page.mount/2` が設定する。ナビゲーションのたびにリセットされ、現在のページ固有の状態を保持する。

```elixir
defmodule MyApp.App.Users.Id do
  use Dialup.Page

  def mount(%{"id" => id}, assigns) do
    # assigns には session の内容が入っている（current_user 等を参照可能）
    post = Posts.get!(id, assigns.current_user)
    {:ok, %{post: post}}  # 返り値が page assigns になる
  end
end
```

`mount/2` の返り値はそのまま page assigns になる（session キーを含める必要はない）。

### params

URLパラメータ（パスパラメータとクエリパラメータの両方）をフレームワークが自動的に設定する。

```elixir
# /users/123?tab=posts にアクセスした場合
def mount(params, assigns) do
  id  = params["id"]   # "123"（パスパラメータ）
  tab = params["tab"]  # "posts"（クエリパラメータ）
  ...
end
```

## テンプレートでのアクセス

render 直前に `session + assigns + params` がマージされるため、テンプレートではすべて `@` でアクセスできる。どのフィールド由来かを意識する必要はない。

```html
<p>{@current_user.name}</p>  <!-- session 由来 -->
<h1>{@post.title}</h1>       <!-- assigns 由来 -->
<p>ページ: {@params["page"]}</p>  <!-- params -->
```

## handle_event での状態更新

`handle_event/3` には `session + assigns + params` がマージされた状態が渡される。返り値も同じ形式で返す。

```elixir
def handle_event("follow", _, assigns) do
  # assigns には current_user（session由来）も post（assigns由来）も含まれる
  new_post = Posts.follow(assigns.post, assigns.current_user)
  {:update, Map.put(assigns, :post, new_post)}
end
```

フレームワークが `session_keys` を使って返り値を session と assigns に自動分割するため、開発者は意識不要。

### session を更新する

`handle_event` の返り値に session キーを含めれば session も更新できる。

```elixir
def handle_event("switch_locale", locale, assigns) do
  {:update, Map.put(assigns, :locale, locale)}
  # :locale が session_keys に含まれていれば session が更新される
end
```

## ナビゲーション時の挙動

```
/users/123 → /users/456 に遷移

session:  変化なし（current_user 等を保持）
assigns:  リセット → page.mount/2 が再実行される
params:   新しいURLのパラメータに更新
```

session をリセットしたい場合は、`handle_event` や `layout.mount` 内で明示的に行う。

## 状態の揮発性

assigns・session はメモリ上に保持される。以下の場合に失われる：

- WebSocket切断後、タイムアウト（デフォルト5分）経過
- サーバー再起動
- プロセスクラッシュ

永続化が必要なデータはDBに保存すること。

## 設計指針

**session に入れるもの**: ページをまたいで共有したい状態（ログインユーザー、言語設定など）

**assigns に入れるもの**: 現在のページ固有の状態（表示中のデータ、フォーム入力、UIフラグ）

**注意**: session と assigns で同じキー名を使うと session が優先される。命名の衝突を避けること。
