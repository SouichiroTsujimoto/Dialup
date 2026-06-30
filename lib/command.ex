defmodule Dialup.Command do
  @moduledoc false

  @doc """
  Builds a Commanded command struct from context, command name, bind map, and request params.
  """
  def build(context_module, command_name, bind, arguments) when is_map(bind) and is_map(arguments) do
    module = command_module(context_module, command_name)

    with {:ok, fields} <- merge_fields(bind, arguments) do
      {:ok, struct(module, fields)}
    end
  rescue
    e in [ArgumentError, UndefinedFunctionError] ->
      {:error, {:invalid_command, Exception.message(e)}}
  end

  @doc """
  Resolves the command struct module for a context and command atom.
  """
  def command_module(context_module, command_name) do
    Module.concat([context_module, Commands, Macro.camelize(to_string(command_name))])
  end

  @doc """
  Maps a dispatch error to a human-readable message using static action error metadata.
  """
  def map_error(action, reason) do
    errors = Map.get(action, :errors, %{})

    key =
      case reason do
        atom when is_atom(atom) -> atom
        {atom, _} when is_atom(atom) -> atom
        _ -> nil
      end

    if key && Map.has_key?(errors, key) do
      Map.fetch!(errors, key)
    else
      "操作を完了できませんでした"
    end
  end

  defp merge_fields(bind, arguments) do
    with {:ok, normalized_bind} <- normalize_key_map(bind),
         {:ok, normalized_args} <-
           normalize_key_map(Map.drop(arguments, ["_version", :_version, "_dialup_actor"])) do
      {:ok, Map.merge(normalized_bind, normalized_args)}
    end
  end

  defp normalize_key_map(map) do
    Enum.reduce_while(map, {:ok, %{}}, fn {k, v}, {:ok, acc} ->
      case key_to_atom(k) do
        {:ok, key} -> {:cont, {:ok, Map.put(acc, key, v)}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp key_to_atom(key) when is_atom(key), do: {:ok, key}

  defp key_to_atom(key) when is_binary(key) do
    {:ok, String.to_existing_atom(key)}
  rescue
    ArgumentError -> {:error, {:invalid_command, "unknown parameter key: #{key}"}}
  end
end
