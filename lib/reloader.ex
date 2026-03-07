defmodule Dialup.Reloader do
  @moduledoc """
  開発時のホットリロード。ソースファイルをポーリングし、変更を検知したら
  再コンパイル → 全セッションに通知する。Phoenix.CodeReloader の設計を参考にしている。
  """
  use GenServer
  require Logger

  @poll_ms 500
  @compilers [:elixir]

  def start_link(dirs) do
    GenServer.start_link(__MODULE__, dirs, name: __MODULE__)
  end

  @impl GenServer
  def init(dirs) do
    Process.send_after(self(), :check, @poll_ms)
    {:ok, %{dirs: dirs, mtimes: scan(dirs)}}
  end

  @impl GenServer
  def handle_info(:check, state) do
    new_mtimes = scan(state.dirs)

    state =
      if new_mtimes != state.mtimes do
        # 変更されたファイルを touch して mtime を現在時刻に揃える。
        # Elixir コンパイラは内部で System.os_time(:second) と比較するため、
        # エディタが付与した mtime がわずかでも先行すると "set to the future" 警告が出る。
        # File.touch! は同じシステムクロックを使うので確実に正規化できる。
        touch_changed(state.mtimes, new_mtimes)

        case recompile() do
          :ok ->
            pids = Registry.select(Dialup.SessionRegistry, [{{:_, :"$1", :_}, [], [:"$1"]}])
            Enum.each(pids, &send(&1, :dialup_reload))

          :error ->
            :ok
        end

        # touch で mtime が変わるため再スキャンして正しい状態を保存
        %{state | mtimes: scan(state.dirs)}
      else
        state
      end

    Process.send_after(self(), :check, @poll_ms)
    {:noreply, state}
  end

  # Phoenix と同様に reenable → run パターンで各コンパイラを実行する。
  # --no-all-warnings: 変更されていないファイルの警告を抑制
  defp recompile do
    Enum.each(@compilers, &Mix.Task.reenable("compile.#{&1}"))

    results =
      Enum.map(@compilers, fn compiler ->
        Mix.Task.run("compile.#{compiler}", ["--no-all-warnings"])
      end)

    if Enum.any?(results, &match?({:error, _}, &1)), do: :error, else: :ok
  rescue
    e ->
      Logger.error("[Dialup.Reloader] Compilation failed: #{Exception.message(e)}")
      :error
  end

  defp touch_changed(old_mtimes, new_mtimes) do
    Enum.each(new_mtimes, fn {path, mtime} ->
      if Map.get(old_mtimes, path) != mtime, do: File.touch!(path)
    end)
  end

  defp scan(dirs) do
    dirs
    |> Enum.flat_map(&Path.wildcard("#{&1}/**/*.ex"))
    |> Map.new(&{&1, File.stat!(&1).mtime})
  end
end
