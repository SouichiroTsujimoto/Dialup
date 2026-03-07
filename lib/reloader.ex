defmodule Dialup.Reloader do
  use GenServer

  @poll_ms 500

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

    if new_mtimes != state.mtimes do
      Mix.Task.rerun("compile", [])

      pids = Registry.select(Dialup.SessionRegistry, [{{:_, :"$1", :_}, [], [:"$1"]}])
      Enum.each(pids, &send(&1, :dialup_reload))
    end

    Process.send_after(self(), :check, @poll_ms)
    {:noreply, %{state | mtimes: new_mtimes}}
  end

  defp scan(dirs) do
    dirs
    |> Enum.flat_map(&Path.wildcard("#{&1}/**/*.ex"))
    |> Map.new(&{&1, File.stat!(&1).mtime})
  end
end
