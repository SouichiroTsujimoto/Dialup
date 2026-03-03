# State Management

assignsによる状態管理の方法。

## Assignsとは

ページとレイアウトが保持する状態。マップ（キー・値）として表現される。

```elixir
%{
  # フレームワークが設定
  params: %{"id" => "123"},
  inner_content: "...",
  
  # ユーザーが設定
  count: 0,
  user: %User{...},
  errors: []
}
```

## 標準的なキー

| キー | 設定元 | 説明 |
|-----|-------|------|
| `params` | Dialup | URLパラメータ |
| `inner_content` | Dialup | レイアウト内で子要素を表示する際に使用 |

## 状態の更新

### 初期化（mount）

```elixir
def mount(params, assigns) do
  assigns
  |> set_default(%{count: 0, items: []})    # デフォルト値を設定
  |> overwrite(%{loaded: true})             # 特定の値で上書き
end
```

### イベント処理（handle_event）

```elixir
def handle_event("add", %{"name" => name}, assigns) do
  new_item = %{id: System.unique_integer(), name: name}
  items = [new_item | assigns.items]
  
  {:update, assigns |> overwrite(%{items: items})}
end
```

## 状態のライフサイクル

### 生存期間

- **セッション単位**: WebSocket接続中は維持
- **URL接頭辞単位**: 共通パス部分は維持、異なる部分は破棄

```
/users/123 → /users/123/edit
→ usersレイヤーのstateは維持

/users/123 → /items/456  
→ usersレイヤーのstateは破棄、itemsレイヤーが新規作成
```

### 揮発性

assignsはメモリ上に保持される。以下の場合に失われる：

- WebSocket切断後、タイムアウト時間経過
- サーバー再起動
- プロセスクラッシュ

永続化が必要なデータはDBなどに保存すること。

## 状態設計の指針

### assignsに含めるべきもの

- UIの表示状態（count, loading, errors）
- 現在表示中のデータ（user, items）
- フォーム入力中の値（draft）

### assignsに含めないべきもの

- 永続化済みデータの全件（ページネーション対象）
- セキュリティ上敏感な情報（パスワード、トークン）
- 大きなバイナリデータ

## パターンマッチの活用

mount内でassignsの構造を検証：

```elixir
def mount(_params, %{current_user: nil} = assigns) do
  # 未ログイン時の処理
  {:ok, assigns |> overwrite(%{require_login: true})}
end

def mount(_params, %{current_user: user} = assigns) do
  # ログイン済み時の処理
  {:ok, assigns |> overwrite(%{profile: user.profile})}
end
```

## 注意点

- assignsは書き換え可能だが、immutabilityを保つ
- 大きなリストはpage単位で保持し、無限スクロールなどを検討
- メモリ使用量に注意（各タブ/ユーザーにプロセスが割り当てられる）
