# Routing

ファイルベースルーティングの仕様と使い方。

## 基本概念

ファイルの配置がそのままURLパスになる。ルーター設定は不要。

```
lib/app/page.ex              → /
lib/app/about/page.ex        → /about
lib/app/users/page.ex        → /users
lib/app/users/[id]/page.ex   → /users/:id
```

## 静的ルーティング

### 基本的な対応

| ファイルパス | URL |
|-------------|-----|
| `app/page.ex` | `/` |
| `app/about/page.ex` | `/about` |
| `app/docs/guide/page.ex` | `/docs/guide` |

### インデックスページ

ディレクトリ配下の `page.ex` が該当パスを担当する。

```
app/users/page.ex    → /users（ユーザー一覧）
app/users/[id]/page.ex → /users/123（ユーザー詳細）
```

## 動的ルーティング

### ブラケット記法

`[パラメータ名]` でURLパラメータを受け取る。

```
app/users/[id]/page.ex    → /users/123, /users/abc など
app/posts/[slug]/page.ex  → /posts/hello-world など
```

### paramsへのアクセス

`mount/2` の第1引数で受け取る。パスパラメータとクエリパラメータが両方含まれる：

```elixir
defmodule MyApp.Users.Id do
  use Dialup.Page

  # /users/123?tab=posts にアクセス
  def mount(params, assigns) do
    id  = params["id"]    # "123"（パスパラメータ）
    tab = params["tab"]   # "posts"（クエリパラメータ）
    user = Users.get!(id)
    {:ok, %{user: user, tab: tab || "profile"}}
  end
end
```

テンプレートからは `@params` でもアクセスできる：

```html
<p>現在のタブ: {@params["tab"]}</p>
```

### クエリパラメータ

クエリ文字列（`?key=value`）は自動的に `params` に含まれる。複数パラメータにも対応：

```
/search?q=elixir&page=2&sort=date
→ params = %{"q" => "elixir", "page" => "2", "sort" => "date"}
```

パスパラメータとクエリパラメータで同名のキーがある場合、パスパラメータが優先される。

### パターンマッチ

異なるパラメータ値で分岐できる：

```elixir
# /users/new → 新規作成画面
def mount(%{"id" => "new"}, assigns) do
  {:ok, assigns |> overwrite(%{mode: :new, user: nil})}
end

# /users/:id → 編集画面
def mount(%{"id" => id}, assigns) do
  user = Users.get!(id)
  {:ok, assigns |> overwrite(%{mode: :edit, user: user})}
end
```

## レイアウトの継承

### レイアウトファイルの配置

```
app/layout.ex              # 全ページの共通レイアウト
app/users/layout.ex        # /users 以下のレイアウト
app/users/[id]/layout.ex   # /users/:id 以下のレイアウト（あれば）
```

### レイアウトの適用ルール

URL `/users/123/profile` の場合：

1. `app/layout.ex`（最上位）
2. `app/users/layout.ex`（中間）
3. `app/users/[id]/page.ex` または `app/users/profile/page.ex`（該当ページ）

レイアウトは上から順にネストされる。

## ルーティングの優先順位

1. **静的ルートを先に探索**（完全一致）
2. **動的ルートにフォールバック**（パターンマッチ）
3. **マッチしない場合は404**

```
app/users/new/page.ex      → 静的: /users/new
app/users/[id]/page.ex     → 動的: /users/:id

/users/new      → 静的ルートが優先
te/users/123     → 動的ルートがマッチ
```

## コロケーション CSS

`page.ex` / `layout.ex` と同じディレクトリに同名の `.css` ファイルを置くと、コンパイル時に自動検出・スコーピングされる。

```
app/
├── layout.ex
├── layout.css      ← 全ページ共通スタイル
├── page.ex
├── page.css        ← / のみに適用
└── docs/
    ├── layout.css  ← /docs 配下全ページに適用
    └── page.css    ← /docs トップのみに適用
```

### スコーピングの仕組み

モジュール名の MD5 先頭 7 文字から `d-xxxxxxx` というスコープクラスを生成し、CSS をネイティブ CSS nesting でラップする：

```css
/* page.css に書いたもの → コンパイル後 */
.d-a1b2c3 {
  h1 { color: blue; }
  .card { padding: 1rem; }
}
```

レンダリング時にそのページの HTML が `<div class="d-a1b2c3">...</div>` でラップされる。CSS は `<style data-dialup-css>` としてその直前に注入される。

### layout.css のカスケード

layout.css のスコープ div は全子ページの HTML を包むため、layout.css に書いたスタイルは配下の全ページに自然にカスケードする：

```html
<div class="d-layout">           <!-- app/layout.css のスコープ -->
  <header>...</header>
  <div class="d-docs-layout">    <!-- docs/layout.css のスコープ -->
    <div class="d-docs-page">    <!-- docs/page.css のスコープ -->
      <h1>Docs</h1>
    </div>
  </div>
</div>
```

### 注意事項

- CSS が存在しないページでは `<style>` タグも wrapper div も出力されない（オーバーヘッドゼロ）
- `.css` 変更時は `@external_resource` 経由で対応する `.ex` が自動再コンパイルされ、ホットリロードが動作する
- CSS nesting はモダンブラウザ 96%+ でサポート（Chrome 120+, Firefox 117+, Safari 17.2+）

## レイアウトのオプトアウト

特定のページでレイアウト継承を無効にし、全画面表示にしたい場合は `@layout false` を指定する。

```elixir
defmodule Dialup.App.Login.Page do
  use Dialup.Page

  @layout false

  def render(assigns) do
    ~H"""
    <div class="fullscreen-login">
      <h1>ログイン</h1>
      <form ws-submit="login">
        <input name="email" placeholder="Email" />
        <input name="password" type="password" />
        <button type="submit">ログイン</button>
      </form>
    </div>
    """
  end
end
```

`@layout false` を指定すると、親ディレクトリの `layout.ex` は適用されず、ページの HTML が直接 Shell に挿入される。コロケーション CSS（`page.css`）は `@layout false` でも適用される。

## エラーページ

### カスタムエラーページ

`app/` ディレクトリに `error.ex` を置くと、404 や 500 エラー時にユーザー定義のエラーページが表示される。`layout.ex` と同様にディレクトリ階層で継承される。

```
app/
├── layout.ex           # 全ページ共通レイアウト
├── error.ex            # 全ページ共通エラーページ
├── page.ex
└── admin/
    ├── layout.ex       # /admin 配下の共通レイアウト
    ├── error.ex        # /admin 配下のエラーページ（より具体的）
    └── page.ex
```

### error.ex の書き方

`use Dialup.Error` を使い、`render/2` でステータスコードごとに表示を分岐する。

```elixir
defmodule Dialup.App.Error do
  use Dialup.Error

  def render(404, assigns) do
    ~H"""
    <div class="error-page">
      <h1>404</h1>
      <p>ページが見つかりませんでした</p>
      <a ws-href="/">ホームへ戻る</a>
    </div>
    """
  end

  def render(500, assigns) do
    ~H"""
    <div class="error-page">
      <h1>500</h1>
      <p>サーバーエラーが発生しました</p>
    </div>
    """
  end

  def render(_status, assigns) do
    ~H"""
    <div class="error-page">
      <h1>{@status}</h1>
      <p>エラーが発生しました</p>
    </div>
    """
  end
end
```

### エラーページの継承

リクエストパスに最も近い `error.ex` が選択される。

- `/admin/users/123` で 404 → `app/admin/error.ex` があればそれ、なければ `app/error.ex`
- `error.ex` が一つも存在しなければフレームワークのデフォルト表示が使われる

### レイアウトとの関係

エラーページは通常のページと同様に layout に囲われて出力される。全画面のエラーページにしたい場合は `@layout false` を指定する。

```elixir
defmodule Dialup.App.Error do
  use Dialup.Error

  @layout false  # layout なしの全画面エラーページ

  def render(404, assigns) do
    ~H"""
    <div class="fullscreen-error">
      <h1>404 Not Found</h1>
    </div>
    """
  end
end
```

### assigns に渡される情報

```elixir
%{
  status: 404,            # HTTP ステータスコード
  message: "Not Found"    # ステータスメッセージ
}
```

500 エラーの場合、開発環境（`Mix.env() == :dev`）ではさらに `exception` と `stacktrace` が含まれる。

### コロケーション CSS

`error.css` を `error.ex` と同じディレクトリに配置すると、ページや layout と同様に自動スコーピングが適用される。

## 制限事項

- 正規表現やカスタムパターンマッチは不可
- `[id]` はURL全体のセグメントにマッチ（`/` を含まない）
- オプショナルパラメータは不可（`/users` と `/users/:id` は別ファイルが必要）
