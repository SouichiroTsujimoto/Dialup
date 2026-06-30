defmodule Dialup.Command do
  @moduledoc false

  @doc """
  Builds a Commanded command struct from context, command name, bind map, and request params.
  """
  def build(context_module, command_name, bind, arguments) when is_map(bind) and is_map(arguments) do
    module = command_module(context_module, command_name)
    fields = merge_fields(bind, arguments)
    {:ok, struct(module, fields)}
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
    normalized_args =
      arguments
      |> Map.drop(["_version", :_version, "_dialup_actor"])
      |> Enum.map(fn {k, v} -> {to_existing_atom(k), v} end)
      |> Map.new()

    bind
    |> Enum.map(fn {k, v} -> {to_existing_atom(k), v} end)
    |> Map.new()
    |> Map.merge(normalized_args)
  end

  defp to_existing_atom(key) when is_atom(key), do: key

  defp to_existing_atom(key) when is_binary(key) do
    try do
      String.to_existing_atom(key)
    rescue
      ArgumentError -> String.to_atom(key)
    end
  end
end
