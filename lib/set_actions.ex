defmodule Dialup.SetActions do
  @moduledoc false

  @key :dialup_set_actions

  def begin_collect do
    Process.put(@key, %{})
  end

  def record(name, updates) when is_map(updates) do
    map = Process.get(@key, %{})
    Process.put(@key, Map.put(map, to_string(name), normalize_keys(updates)))
  end

  def collect, do: Process.get(@key, %{})

  def clear, do: Process.delete(@key)

  defp normalize_keys(map) do
    Map.new(map, fn {k, v} -> {to_existing_atom!(k), v} end)
  end

  defp to_existing_atom!(key) when is_atom(key), do: key

  defp to_existing_atom!(key) when is_binary(key) do
    String.to_existing_atom(key)
  end
end
