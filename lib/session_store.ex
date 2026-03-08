defmodule Dialup.SessionStore do
  @moduledoc """
  ETS ベースのセッション永続化ストア。プロセス終了時にセッション状態を保存し、
  再起動後に復元可能にする。オプトイン方式。
  """

  use GenServer

  @table :dialup_session_store

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl GenServer
  def init(_) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{}}
  end

  def save(session_id, session, assigns, path) do
    :ets.insert(@table, {session_id, %{session: session, assigns: assigns, path: path}})
    :ok
  end

  def restore(session_id) do
    case :ets.lookup(@table, session_id) do
      [{^session_id, data}] ->
        :ets.delete(@table, session_id)
        {:ok, data}

      [] ->
        :error
    end
  end

  def delete(session_id) do
    :ets.delete(@table, session_id)
    :ok
  end
end
