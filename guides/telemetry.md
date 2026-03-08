# Telemetry

Dialup は `:telemetry` ライブラリを使って計測ポイントを提供する。WebSocket 接続数、イベント処理時間、エラー率などを監視できる。

## イベント一覧

### WebSocket

| イベント | 計測値 | メタデータ |
|---------|--------|-----------|
| `[:dialup, :websocket, :connect]` | `%{count: 1}` | `%{session_id: "..."}` |
| `[:dialup, :websocket, :disconnect]` | `%{count: 1}` | `%{session_id: "..."}` |

### イベント処理

| イベント | 計測値 | メタデータ |
|---------|--------|-----------|
| `[:dialup, :event, :start]` | `%{system_time: integer}` | `%{event: "increment", path: "/"}` |
| `[:dialup, :event, :stop]` | `%{duration: integer}` | `%{event: "increment", path: "/"}` |
| `[:dialup, :event, :exception]` | `%{duration: integer}` | `%{event: "increment", path: "/", kind: :error, reason: %RuntimeError{}, stacktrace: [...]}` |

`duration` は `System.monotonic_time()` のネイティブ単位。ミリ秒に変換するには `System.convert_time_unit(duration, :native, :millisecond)` を使う。

すべての `start` に対して `stop` か `exception` のどちらかが必ず発火する。

### ナビゲーション

| イベント | 計測値 | メタデータ |
|---------|--------|-----------|
| `[:dialup, :navigate, :start]` | `%{system_time: integer}` | `%{path: "/users/123"}` |
| `[:dialup, :navigate, :stop]` | `%{duration: integer}` | `%{path: "/users/123"}` |
| `[:dialup, :navigate, :exception]` | `%{duration: integer}` | `%{path: "/users/123", kind: :error, reason: %RuntimeError{}, stacktrace: [...]}` |

## ハンドラの登録

アプリケーション起動時に `:telemetry.attach_many` でハンドラを登録する。

**重要**: `use Dialup` を含むモジュールはホットリロード時に再コンパイルされるため、テレメトリハンドラは別モジュールに切り出す必要がある。同じモジュール内に `defp` で定義すると、関数参照が無効化されて `:badfun` エラーになる。

```elixir
# lib/my_app.ex
defmodule MyApp do
  use Application

  use Dialup,
    app_dir: __DIR__ <> "/app",
    title: "My App"

  @impl Application
  def start(_type, _args) do
    MyApp.Telemetry.attach()

    children = [{Dialup, app: __MODULE__, port: 4000}]
    Supervisor.start_link(children, strategy: :one_for_one)
  end
end
```

```elixir
# lib/telemetry.ex
defmodule MyApp.Telemetry do
  require Logger

  def attach do
    :telemetry.attach_many(
      "my-app-telemetry",
      [
        [:dialup, :websocket, :connect],
        [:dialup, :websocket, :disconnect],
        [:dialup, :event, :stop],
        [:dialup, :event, :exception],
        [:dialup, :navigate, :stop],
        [:dialup, :navigate, :exception]
      ],
      &__MODULE__.handle/4,
      nil
    )
  end

  def handle([:dialup, :websocket, :connect], _measurements, meta, _config) do
    Logger.info("[ws] connected: #{meta.session_id}")
  end

  def handle([:dialup, :websocket, :disconnect], _measurements, meta, _config) do
    Logger.info("[ws] disconnected: #{meta.session_id}")
  end

  def handle([:dialup, :event, :stop], %{duration: d}, meta, _config) do
    ms = System.convert_time_unit(d, :native, :millisecond)
    Logger.info("[event] #{meta.event} on #{meta.path} (#{ms}ms)")
  end

  def handle([:dialup, :event, :exception], %{duration: d}, meta, _config) do
    ms = System.convert_time_unit(d, :native, :millisecond)
    Logger.error("[event] #{meta.event} on #{meta.path} failed (#{ms}ms): #{Exception.message(meta.reason)}")
  end

  def handle([:dialup, :navigate, :stop], %{duration: d}, meta, _config) do
    ms = System.convert_time_unit(d, :native, :millisecond)
    Logger.info("[navigate] #{meta.path} (#{ms}ms)")
  end

  def handle([:dialup, :navigate, :exception], %{duration: d}, meta, _config) do
    ms = System.convert_time_unit(d, :native, :millisecond)
    Logger.error("[navigate] #{meta.path} failed (#{ms}ms): #{Exception.message(meta.reason)}")
  end

  def handle(_event, _measurements, _meta, _config), do: :ok
end
```

## telemetry_metrics との連携

`Telemetry.Metrics` を使ったダッシュボード向けのメトリクス定義例：

```elixir
defp metrics do
  [
    Telemetry.Metrics.counter("dialup.websocket.connect.count"),
    Telemetry.Metrics.counter("dialup.websocket.disconnect.count"),
    Telemetry.Metrics.distribution("dialup.event.stop.duration",
      unit: {:native, :millisecond},
      tags: [:event, :path]
    ),
    Telemetry.Metrics.counter("dialup.event.exception.duration",
      tags: [:event, :path]
    ),
    Telemetry.Metrics.distribution("dialup.navigate.stop.duration",
      unit: {:native, :millisecond},
      tags: [:path]
    )
  ]
end
```
