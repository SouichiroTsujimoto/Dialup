defmodule Dialup.Agent.RegistryProxy do
  @moduledoc false
  use GenServer

  def start_link(session_pid, token) do
    GenServer.start_link(__MODULE__, {session_pid, token})
  end

  @impl GenServer
  def init({session_pid, token}) do
    :yes = :global.register_name({Dialup.Agent, token}, self())
    ref = Process.monitor(session_pid)
    {:ok, %{session_pid: session_pid, ref: ref}}
  end

  @impl GenServer
  def handle_call(:session_pid, _from, state), do: {:reply, state.session_pid, state}

  @impl GenServer
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{ref: ref} = state) do
    {:stop, :normal, state}
  end
end
