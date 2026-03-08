defmodule Dialup.Telemetry do
  @moduledoc """
  Dialup フレームワークの Telemetry イベント定義とヘルパー。

  ## イベント一覧

  ### WebSocket
  - `[:dialup, :websocket, :connect]`
  - `[:dialup, :websocket, :disconnect]`

  ### イベント処理（handle_event）
  - `[:dialup, :event, :start]`
  - `[:dialup, :event, :stop]`
  - `[:dialup, :event, :exception]`

  ### ナビゲーション
  - `[:dialup, :navigate, :start]`
  - `[:dialup, :navigate, :stop]`
  - `[:dialup, :navigate, :exception]`
  """

  def websocket_connect(metadata) do
    :telemetry.execute([:dialup, :websocket, :connect], %{count: 1}, metadata)
  end

  def websocket_disconnect(metadata) do
    :telemetry.execute([:dialup, :websocket, :disconnect], %{count: 1}, metadata)
  end

  @doc "handle_event 処理の開始を記録し、start_time を返す。"
  def event_start(event_name, path) do
    metadata = %{event: event_name, path: path}
    start_time = System.monotonic_time()
    :telemetry.execute([:dialup, :event, :start], %{system_time: System.system_time()}, metadata)
    start_time
  end

  @doc "handle_event 処理の正常完了を記録する。"
  def event_stop(start_time, event_name, path) do
    metadata = %{event: event_name, path: path}
    duration = System.monotonic_time() - start_time
    :telemetry.execute([:dialup, :event, :stop], %{duration: duration}, metadata)
  end

  @doc "handle_event 処理中の例外を記録する。"
  def event_exception(start_time, event_name, path, kind, reason, stacktrace) do
    metadata = %{event: event_name, path: path, kind: kind, reason: reason, stacktrace: stacktrace}
    duration = System.monotonic_time() - start_time
    :telemetry.execute([:dialup, :event, :exception], %{duration: duration}, metadata)
  end

  @doc "ナビゲーション処理の開始を記録し、start_time を返す。"
  def navigate_start(path) do
    metadata = %{path: path}
    start_time = System.monotonic_time()
    :telemetry.execute([:dialup, :navigate, :start], %{system_time: System.system_time()}, metadata)
    start_time
  end

  @doc "ナビゲーション処理の正常完了を記録する。"
  def navigate_stop(start_time, path) do
    metadata = %{path: path}
    duration = System.monotonic_time() - start_time
    :telemetry.execute([:dialup, :navigate, :stop], %{duration: duration}, metadata)
  end

  @doc "ナビゲーション処理中の例外を記録する。"
  def navigate_exception(start_time, path, kind, reason, stacktrace) do
    metadata = %{path: path, kind: kind, reason: reason, stacktrace: stacktrace}
    duration = System.monotonic_time() - start_time
    :telemetry.execute([:dialup, :navigate, :exception], %{duration: duration}, metadata)
  end
end
