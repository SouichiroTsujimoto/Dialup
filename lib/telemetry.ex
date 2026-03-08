defmodule Dialup.Telemetry do
  @moduledoc """
  Dialup フレームワークの Telemetry イベント定義とヘルパー。

  ## イベント一覧

  - `[:dialup, :websocket, :connect]` -- WebSocket 接続確立
  - `[:dialup, :websocket, :disconnect]` -- WebSocket 切断
  - `[:dialup, :event, :start]` / `[:dialup, :event, :stop]` -- handle_event の処理
  - `[:dialup, :navigate, :start]` / `[:dialup, :navigate, :stop]` -- ナビゲーション処理
  - `[:dialup, :error]` -- エラー発生
  """

  def websocket_connect(metadata \\ %{}) do
    :telemetry.execute([:dialup, :websocket, :connect], %{count: 1}, metadata)
  end

  def websocket_disconnect(metadata \\ %{}) do
    :telemetry.execute([:dialup, :websocket, :disconnect], %{count: 1}, metadata)
  end

  def event_start(event_name, metadata \\ %{}) do
    start_time = System.monotonic_time()
    :telemetry.execute([:dialup, :event, :start], %{system_time: System.system_time()}, Map.put(metadata, :event, event_name))
    start_time
  end

  def event_stop(start_time, event_name, metadata \\ %{}) do
    duration = System.monotonic_time() - start_time
    :telemetry.execute([:dialup, :event, :stop], %{duration: duration}, Map.put(metadata, :event, event_name))
  end

  def navigate_start(path, metadata \\ %{}) do
    start_time = System.monotonic_time()
    :telemetry.execute([:dialup, :navigate, :start], %{system_time: System.system_time()}, Map.put(metadata, :path, path))
    start_time
  end

  def navigate_stop(start_time, path, metadata \\ %{}) do
    duration = System.monotonic_time() - start_time
    :telemetry.execute([:dialup, :navigate, :stop], %{duration: duration}, Map.put(metadata, :path, path))
  end

  def error(exception, metadata \\ %{}) do
    :telemetry.execute([:dialup, :error], %{count: 1}, Map.put(metadata, :exception, exception))
  end
end
