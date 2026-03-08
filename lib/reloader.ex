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
        # コンパイル前に未来 mtime を修正する。
        # Mix は全ファイルの mtime をチェックするため、未変更ファイルも含めて対象にする。
        fix_future_mtimes(new_mtimes)

        case recompile() do
          :ok ->
            pids = Registry.select(Dialup.SessionRegistry, [{{:_, :"$1", :_}, [], [:"$1"]}])
            Enum.each(pids, &send(&1, :dialup_reload))

          :error ->
            :ok
        end

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

  defp fix_future_mtimes(mtimes) do
    now = :calendar.universal_time()
    past = then(now, fn {{y, m, d}, {h, min, s}} -> {{y, m, d}, {h, min, max(s - 1, 0)}} end)
    Enum.each(mtimes, fn {path, mtime} ->
      if mtime > now, do: File.touch!(path, past)
    end)
  end

  defp scan(dirs) do
    dirs
    |> Enum.flat_map(&Path.wildcard("#{&1}/**/*.{ex,css}"))
    |> Map.new(&{&1, File.stat!(&1).mtime})
  end
end
