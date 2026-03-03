# Helpers

Dialup.Page が提供するヘルパー関数。

## 概要

`Map.merge/2` のラッパー関数。assignsを第一引数に取ることで、パイプライン操作に最適化されている。

```elixir
use Dialup.Page  # で自動的に import される
```

## overwrite/2

assignsを上書き。既存のキーは新しい値で上書きされる。

```elixir
overwrite(assigns, overwrite_map)
```

### 使用例

パイプラインで連結：

```elixir
def mount(params, assigns) do
  id = params["id"]
  user = Users.get!(id)
  
  assigns
  |> overwrite(%{user_id: id})      # assignsを第一引数に取る
  |> overwrite(%{user: user})       # パイプラインで連結可能
end
```

### 動作

```elixir
base = %{count: 0, user_id: "old"}

base |> overwrite(%{user_id: "123"})
# => %{count: 0, user_id: "123"}
```

## set_default/2

デフォルト値を設定。既存のキーは上書きしない。

```elixir
set_default(assigns, defaults_map)
```

### 使用例

```elixir
def mount(_params, assigns) do
  assigns
  |> set_default(%{count: 0})       # 未設定の場合のみ設定
  |> set_default(%{loaded: false})
end
```

### 動作

```elixir
base = %{count: 5}

base |> set_default(%{count: 0, loaded: false})
# => %{count: 5, loaded: false}
```

## 使い分け

| 関数 | 既存キー | 用途 |
|-----|---------|------|
| `overwrite/2` | 上書き | 新しいデータで状態を更新 |
| `set_default/2` | 保持 | 初期値の設定（初回のみ） |

## パイプラインでの併用例

```elixir
def mount(params, assigns) do
  # 1. デフォルト値を設定（初回のみ有効）
  # 2. URLパラメータに応じて上書き
  assigns
  |> set_default(%{count: 0, errors: []})
  |> overwrite(%{user_id: params["id"], loaded: true})
end
```

```elixir
def handle_event("add_error", %{"msg" => msg}, assigns) do
  errors = [msg | assigns.errors]
  
  {:update, assigns |> overwrite(%{errors: errors})}
end

def handle_event("clear", _value, assigns) do
  {:update, assigns |> overwrite(%{errors: [], input: ""})}
end
```

## 標準ライブラリとの比較

### 同等の書き方

```elixir
# overwrite
assigns |> Map.merge(%{count: 1})

# set_default  
%{count: 0} |> Map.merge(assigns)
```

ヘルパー関数は意図を明確にし、一貫したパイプラインスタイルを保つためのもの。

## 制限

- ネストしたマップのマージは行わない（浅いマージのみ）
- リストの操作は別途行う必要がある
