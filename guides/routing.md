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

`mount/2` の第1引数で受け取る：

```elixir
defmodule MyApp.Users.Id do
  use Dialup.Page

  def mount(params, assigns) do
    id = params["id"]        # "123"
    user = Users.get!(id)
    {:ok, assigns |> overwrite(%{user: user})}
  end
end
```

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

## 制限事項

- 正規表現やカスタムパターンマッチは不可
- `[id]` はURL全体のセグメントにマッチ（`/` を含まない）
- オプショナルパラメータは不可（`/users` と `/users/:id` は別ファイルが必要）
