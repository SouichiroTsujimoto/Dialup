# Fullstack Example

Ecto（DB）とPubSub（リアルタイム通信）を組み合わせたフルスタックアプリケーションの作成例。

## このガイドで作るもの

**リアルタイム掲示板**:
- 投稿をDB（PostgreSQL）に保存
- 複数のブラウザで同時閲覧時、新規投稿が即座に全員の画面に反映
- 投稿の編集・削除もリアルタイム同期

## 前提条件

- PostgreSQLがインストール済み
- Elixir 1.19以上

---

## ステップ1: プロジェクト作成

まだ `mix dialup.new` をインストールしていない場合は先にインストール：

```bash
mix archive.install hex dialup_new
```

`mix dialup.new` ジェネレータを使用する。`root.html.heex`、`lib/app/` 以下のファイル、`mix.exs` の設定が自動生成される：

```bash
mix dialup.new my_app
cd my_app
```

---

## ステップ2: 依存の追加

`mix.exs` の `deps` にEctoとPubSubを追加：

```elixir
defp deps do
  [
    {:dialup, "~> 0.1"},

    # Ecto（DB接続）
    {:ecto_sql, "~> 3.0"},
    {:postgrex, ">= 0.0.0"},

    # PubSub（リアルタイム通信）
    {:phoenix_pubsub, "~> 2.0"}
  ]
end
```

```bash
mix deps.get
```

---

## ステップ3: データベース設定

### 3-1. DB設定ファイルの作成

`config/config.exs` を作成：

```elixir
import Config

config :my_app, ecto_repos: [MyApp.Repo]
```

`config/runtime.exs` を作成（または編集）：

```elixir
import Config

# Ecto用のDB接続設定
config :my_app, MyApp.Repo,
  database: System.get_env("DB_NAME", "my_app_dev"),
  username: System.get_env("DB_USER", System.get_env("USER", "postgres")),
  password: System.get_env("DB_PASS", ""),
  hostname: System.get_env("DB_HOST", "localhost")
```

> **macOSの場合**: HomebrewでインストールしたpostgresqlはデフォルトのロールがOSのユーザー名になります。
> `DB_USER` 環境変数を設定するか、`createuser -s postgres` でpostgresロールを作成してください。

### 3-2. Repoモジュールの作成

`lib/my_app/repo.ex` を**手動で作成**：

```elixir
defmodule MyApp.Repo do
  use Ecto.Repo,
    otp_app: :my_app,
    adapter: Ecto.Adapters.Postgres
end
```

**補足**: RepoはEctoがDBにアクセスするためのモジュール。`use Ecto.Repo` で自動的に `get`, `insert`, `update` などの関数が使えるようになる。

---

## ステップ4: テーブル作成（マイグレーション）

### 4-1. マイグレーションファイルの作成

マイグレーションは**手動で作成**します。ファイル名には日時を含めるのが一般的：

```bash
# ディレクトリ作成
mkdir -p priv/repo/migrations

# マイグレーションファイル作成
# ファイル名の先頭の数字は実行順序（日時推奨）
touch priv/repo/migrations/20240304000001_create_posts.exs
```

### 4-2. マイグレーション内容の記述

`priv/repo/migrations/20240304000001_create_posts.exs` を編集：

```elixir
defmodule MyApp.Repo.Migrations.CreatePosts do
  use Ecto.Migration

  def change do
    # :posts テーブルを作成
    create table(:posts) do
      add :title, :string, null: false    # タイトル（必須）
      add :content, :text, null: false    # 内容（必須）
      timestamps()                        # inserted_at, updated_at自動追加
    end
  end
end
```

**補足**: `mix ecto.gen.migration` コマンドでも生成できるが、手動作成でも同じ。

### 4-3. DBとテーブルの作成

```bash
# DB作成（初回のみ）
mix ecto.create

# マイグレーション実行（テーブル作成）
mix ecto.migrate
```

実行後、PostgreSQL内に `posts` テーブルが作成される。

---

## ステップ5: Schema（データ構造）の定義

`lib/my_app/post.ex` を**手動で作成**：

```elixir
defmodule MyApp.Post do
  use Ecto.Schema
  import Ecto.Changeset

  # DBのpostsテーブルと対応
  schema "posts" do
    field :title, :string
    field :content, :string
    timestamps()  # inserted_at, updated_at
  end

  # バリデーション用関数
  def changeset(post, attrs) do
    post
    |> cast(attrs, [:title, :content])
    |> validate_required([:title, :content])
  end
end
```

**補足**: 
- `schema` マクロでDBテーブルとElixir構造体のマッピングを定義
- `changeset` はデータの検証・変換を行う（必須項目チェックなど）

---

## ステップ6: Applicationの設定

`mix dialup.new` で生成された `lib/my_app.ex` を編集し、RepoとPubSubを `children` に追加：

```elixir
defmodule MyApp do
  use Application
  use Dialup, app_dir: __DIR__ <> "/app"

  @impl Application
  def start(_type, _args) do
    children = [
      # DB接続プール
      MyApp.Repo,

      # PubSub（リアルタイム通信）
      {Phoenix.PubSub, name: MyApp.PubSub},

      # Dialupサーバー（生成時から存在）
      {Dialup, app: __MODULE__, port: 4000}
    ]

    Supervisor.start_link(children,
      strategy: :one_for_one,
      name: __MODULE__.Supervisor
    )
  end
end
```

**補足**: `children` の順序は重要。Repo → PubSub → Dialup の順で起動。

---

## ステップ7: ページ実装

`mix dialup.new` で `lib/app/layout.ex`、`lib/app/error.ex`、`lib/app/page.ex` は生成済み。
一覧ページと詳細ページを追加していく。

### 7-1. レイアウトを掲示板用に書き換え

生成済みの `lib/app/layout.ex` の `render/1` を以下に置き換える（`mount/1` はそのまま残す）：

```elixir
  def render(assigns) do
    ~H"""
    <div style="max-width: 800px; margin: 0 auto; padding: 20px;">
      <h1>📝 Dialup Board</h1>
      {raw(@inner_content)}
    </div>
    """
  end
```

### 7-2. 一覧ページを書き換え（投稿表示・作成）

生成済みの `lib/app/page.ex` を以下の内容で**置き換え**：

```elixir
defmodule Dialup.App.Page do
  use Dialup.Page
  alias MyApp.{Repo, Post}

  # ページ表示時に呼ばれる
  def mount(_params, assigns) do
    # PubSubで "posts:all" トピックを購読
    # → 他のユーザーが投稿した時に通知を受け取る
    # subscribe/2 はページ離脱時に自動解除される
    subscribe(MyApp.PubSub, "posts:all")

    # DBから投稿一覧を取得（新しい順）
    posts = Repo.all(Post) |> Enum.reverse()

    {:ok, assigns |> set_default(%{posts: posts, errors: []})}
  end

  # フォーム送信時に呼ばれる
  def handle_event("create", %{"title" => title, "content" => content}, assigns) do
    # 1. DBに保存を試みる
    case %Post{} |> Post.changeset(%{title: title, content: content}) |> Repo.insert() do
      {:ok, post} ->
        # 2. 成功：他のセッションに通知
        Phoenix.PubSub.broadcast(MyApp.PubSub, "posts:all", {:post_created, post})
        
        # 3. 自分の画面も更新（エラー消去）
        {:update, assigns |> overwrite(%{errors: []})}
        
      {:error, changeset} ->
        # バリデーションエラーを表示
        errors = Ecto.Changeset.traverse_errors(changeset, fn {msg, _opts} -> msg end)
        {:update, assigns |> overwrite(%{errors: errors})}
    end
  end

  # 他のセッションからの通知を受信
  def handle_info({:post_created, new_post}, assigns) do
    # 新規投稿を一覧に追加
    posts = [new_post | assigns.posts]
    {:update, assigns |> overwrite(%{posts: posts})}
  end

  def render(assigns) do
    ~H"""
    <!-- 投稿フォーム -->
    <form ws-submit="create" style="margin-bottom: 30px; padding: 15px; background: #f5f5f5;">
      <h3>新規投稿</h3>
      <div style="margin-bottom: 10px;">
        <input name="title" placeholder="タイトル" style="width: 100%; padding: 8px; box-sizing: border-box;" />
      </div>
      <div style="margin-bottom: 10px;">
        <textarea name="content" placeholder="内容" style="width: 100%; height: 80px; padding: 8px; box-sizing: border-box;"></textarea>
      </div>
      <button type="submit">投稿する</button>
      
      <!-- エラー表示 -->
      <%= for {field, msgs} <- @errors do %>
        <p style="color: red; margin: 5px 0;">{field}: {Enum.join(msgs, ", ")}</p>
      <% end %>
    </form>
    
    <!-- 投稿一覧 -->
    <h2>投稿一覧</h2>
    <div id="posts">
      <%= for post <- @posts do %>
        <div style="border: 1px solid #ddd; padding: 15px; margin: 10px 0; border-radius: 4px;">
          <h3><a ws-href={"/posts/#{post.id}"}>{post.title}</a></h3>
          <p>{post.content}</p>
          <small style="color: #666;">投稿日時: {post.inserted_at}</small>
        </div>
      <% end %>
    </div>
    """
  end
end
```

**ポイント解説**:
- `subscribe/2`: このページを開いている間、指定トピックの通知を受け取る。ページ離脱時に自動解除される
- `Phoenix.PubSub.broadcast/3`: 同じトピックを購読している全員にメッセージ送信
- `handle_info`: 他のセッションからの通知を処理

### 7-3. 詳細ページ（編集・削除）

新規ファイルを作成：

```bash
mkdir -p lib/app/posts/[id]
```

`lib/app/posts/[id]/page.ex` を**新規作成**：

```elixir
defmodule Dialup.App.Posts.Id.Page do
  use Dialup.Page
  alias MyApp.{Repo, Post}

  def mount(%{"id" => id}, assigns) do
    # この投稿専用のトピックを購読（編集時のリアルタイム反映用）
    subscribe(MyApp.PubSub, "post:#{id}")

    # DBから特定の投稿を取得
    post = Repo.get(Post, id)

    {:ok, assigns |> overwrite(%{post: post, editing: false})}
  end

  # 削除ボタン押下時
  def handle_event("delete", _value, assigns) do
    # DBから削除
    Repo.delete!(assigns.post)
    
    # 一覧ページに通知（一覧の表示を更新するため）
    Phoenix.PubSub.broadcast(MyApp.PubSub, "posts:all", {:post_deleted, assigns.post.id})
    
    {:update, assigns |> overwrite(%{deleted: true})}
  end

  # 編集モード切り替え
  def handle_event("toggle_edit", _value, assigns) do
    {:update, assigns |> overwrite(%{editing: !assigns.editing})}
  end

  # 編集保存時
  def handle_event("update", %{"title" => title, "content" => content}, assigns) do
    case assigns.post |> Post.changeset(%{title: title, content: content}) |> Repo.update() do
      {:ok, updated_post} ->
        # この投稿を閲覧中の他ユーザーに通知
        Phoenix.PubSub.broadcast(MyApp.PubSub, "post:#{updated_post.id}", {:post_updated, updated_post})
        
        {:update, assigns |> overwrite(%{post: updated_post, editing: false})}
        
      {:error, _} ->
        {:noreply, assigns}
    end
  end

  # 他のユーザーによる編集を受信
  def handle_info({:post_updated, updated_post}, assigns) do
    {:update, assigns |> overwrite(%{post: updated_post})}
  end

  def render(assigns) do
    ~H"""
    <%= if assigns[:deleted] do %>
      <p>削除されました。<a ws-href="/">一覧へ戻る</a></p>
    <% else %>
      <a ws-href="/">← 一覧へ戻る</a>
      
      <%= if @editing do %>
        <!-- 編集フォーム -->
        <form ws-submit="update" style="margin-top: 20px;">
          <input name="title" value={@post.title} style="width: 100%; padding: 8px; font-size: 1.2em;" />
          <textarea name="content" style="width: 100%; height: 150px; padding: 8px; margin-top: 10px;">{@post.content}</textarea>
          <div style="margin-top: 10px;">
            <button type="submit">保存</button>
            <button type="button" ws-event="toggle_edit">キャンセル</button>
          </div>
        </form>
      <% else %>
        <!-- 表示モード -->
        <article style="margin-top: 20px; padding: 20px; border: 1px solid #ddd; border-radius: 4px;">
          <h1>{@post.title}</h1>
          <p style="line-height: 1.6;">{@post.content}</p>
          <small style="color: #666;">投稿日時: {@post.inserted_at}</small>
          
          <div style="margin-top: 20px;">
            <button ws-event="toggle_edit">✏️ 編集</button>
            <button ws-event="delete" style="color: red; margin-left: 10px;">🗑️ 削除</button>
          </div>
        </article>
      <% end %>
    <% end %>
    """
  end
end
```

---

## ステップ8: 起動と動作確認

### 8-1. 起動

```bash
mix run --no-halt
```

### 8-2. 動作確認手順

1. **ブラウザ1**で `http://localhost:4000` を開く
2. **ブラウザ2**（シークレットウィンドウ等）でも同じURLを開く
3. **ブラウザ1**で新規投稿
   - ブラウザ2に即座に表示されることを確認
4. **ブラウザ2**で投稿をクリックして詳細ページへ
5. **ブラウザ1**でも同じ投稿の詳細ページを開く
6. **ブラウザ1**で編集→保存
   - ブラウザ2の内容が即座に更新されることを確認

---

## トラブルシューティング

### DB接続エラー

```
** (DBConnection.ConnectionError) connection not available
```
→ PostgreSQLが起動しているか確認

### ロールが存在しないエラー（macOS）

```
FATAL 28000 (invalid_authorization_specification) role "postgres" does not exist
```
→ macOSのHomebrewインストールではデフォルトロールがOSユーザー名になる。以下のいずれかで対処：
```bash
# 方法1: postgresロールを作成
createuser -s postgres

# 方法2: 環境変数でユーザーを指定して起動
DB_USER=$(whoami) mix run --no-halt
```

### マイグレーションエラー

```
** (Postgrex.Error) ERROR 42P01 (undefined_table) relation "posts" does not exist
```
→ `mix ecto.migrate` を実行し忘れている可能性

### PubSubが動作しない

→ 複数ブラウザでテスト。同じセッション（同じクッキー）では動作しない。

---

## まとめ

| コンポーネント | 役割 | Dialupとの関係 |
|-------------|------|--------------|
| **Ecto** | DBアクセス | Dialupは関与せず、普通に使う |
| **Phoenix.PubSub** | プロセス間通信 | Dialupは関与せず、普通に使う |
| **Dialup** | WebSocket + ルーティング | コア機能 |

**重要なポイント**: Dialupはこれらのライブラリを「隠蔽」しない。各ライブラリの標準的な使い方がそのまま活きる。

次のステップ:
- [Deployment](./deployment.md) - 本番環境へのデプロイ方法
