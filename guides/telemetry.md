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

`duration` は `System.monotonic_time()` のネイティブ単位。秒に変換するには `System.convert_time_unit(duration, :native, :millisecond)` を使う。

### ナビゲーション

| イベント | 計測値 | メタデータ |
|---------|--------|-----------|
| `[:dialup, :navigate, :start]` | `%{system_time: integer}` | `%{path: "/users/123"}` |
| `[:dialup, :navigate, :stop]` | `%{duration: integer}` | `%{path: "/users/123"}` |

### エラー

| イベント | 計測値 | メタデータ |
|---------|--------|-----------|
| `[:dialup, :error]` | `%{count: 1}` | `%{exception: %RuntimeError{...}, path: "/"}` |

## ハンドラの登録

アプリケーション起動時に `:telemetry.attach` でハンドラを登録する。

```elixir
defmodule MyApp do
  use Application

  use Dialup,
    app_dir: __DIR__ <> "/app",
    title: "My App"

  @impl Application
  def start(_type, _args) do
    attach_telemetry()

    children = [{Dialup, app: __MODULE__, port: 4000}]
    Supervisor.start_link(children, strategy: :one_for_one)
  end

  defp attach_telemetry do
    :telemetry.attach_many(
      "my-app-telemetry",
      [
        [:dialup, :websocket, :connect],
        [:dialup, :websocket, :disconnect],
        [:dialup, :event, :stop],
        [:dialup, :error]
      ],
      &handle_telemetry/4,
      nil
    )
  end

  defp handle_telemetry([:dialup, :websocket, :connect], _measurements, meta, _config) do
    IO.puts("[ws] connected: #{meta.session_id}")
  end

  defp handle_telemetry([:dialup, :event, :stop], measurements, meta, _config) do
    ms = System.convert_time_unit(measurements.duration, :native, :millisecond)
    IO.puts("[event] #{meta.event} on #{meta.path} took #{ms}ms")
  end

  defp handle_telemetry([:dialup, :error], _measurements, meta, _config) do
    IO.puts("[error] #{Exception.message(meta.exception)} on #{meta.path}")
  end

  defp handle_telemetry(_event, _measurements, _meta, _config), do: :ok
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
    Telemetry.Metrics.counter("dialup.error.count", tags: [:path])
  ]
end
```
