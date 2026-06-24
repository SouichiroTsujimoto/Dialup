defmodule Dialup.Agent.Validator do
  @moduledoc false

  def validate(action, arguments) when is_map(arguments) do
    specs = Map.get(action, :params, %{})

    with {:ok, arguments} <- apply_defaults(specs, arguments),
         :ok <- validate_unknown(specs, arguments),
         :ok <- validate_required(specs, arguments),
         :ok <- validate_types(specs, arguments) do
      {:ok, arguments}
    end
  end

  def validate(_action, _arguments),
    do: {:error, [%{"field" => nil, "message" => "must be an object"}]}

  defp apply_defaults(specs, arguments) do
    result =
      Enum.reduce(specs, arguments, fn {name, spec}, acc ->
        key = to_string(name)
        {_type, opts} = normalize_spec(spec)

        if not Map.has_key?(acc, key) and Keyword.has_key?(opts, :default) do
          Map.put(acc, key, Keyword.fetch!(opts, :default))
        else
          acc
        end
      end)

    {:ok, result}
  end

  defp validate_required(specs, arguments) do
    errors =
      specs
      |> Enum.flat_map(fn {name, spec} ->
        key = to_string(name)
        {_type, opts} = normalize_spec(spec)

        if not Keyword.has_key?(opts, :default) and not Map.has_key?(arguments, key) do
          [%{"field" => key, "message" => "is required"}]
        else
          []
        end
      end)

    if errors == [], do: :ok, else: {:error, errors}
  end

  defp validate_unknown(specs, arguments) do
    allowed = specs |> Map.keys() |> Enum.map(&to_string/1) |> MapSet.new()

    errors =
      arguments
      |> Map.keys()
      |> Enum.reject(&MapSet.member?(allowed, &1))
      |> Enum.map(&%{"field" => &1, "message" => "is not allowed"})

    if errors == [], do: :ok, else: {:error, errors}
  end

  defp validate_types(specs, arguments) do
    errors =
      specs
      |> Enum.flat_map(fn {name, spec} ->
        key = to_string(name)

        case Map.fetch(arguments, key) do
          :error ->
            []

          {:ok, value} ->
            {type, opts} = normalize_spec(spec)

            cond do
              not valid_type?(type, value) ->
                [%{"field" => key, "message" => "must be #{type}"}]

              Keyword.has_key?(opts, :enum) and value not in Keyword.fetch!(opts, :enum) ->
                [%{"field" => key, "message" => "must be one of the declared enum values"}]

              true ->
                []
            end
        end
      end)

    if errors == [], do: :ok, else: {:error, errors}
  end

  defp valid_type?(:string, value), do: is_binary(value)
  defp valid_type?(:integer, value), do: is_integer(value)
  defp valid_type?(:number, value), do: is_number(value)
  defp valid_type?(:boolean, value), do: is_boolean(value)
  defp valid_type?(:object, value), do: is_map(value)
  defp valid_type?(:array, value), do: is_list(value)
  defp valid_type?(_type, _value), do: true

  defp normalize_spec({type, default}) when not is_list(default), do: {type, [default: default]}
  defp normalize_spec({type, opts}) when is_list(opts), do: {type, opts}
  defp normalize_spec(type), do: {type, []}
end
