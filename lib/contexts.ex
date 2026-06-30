defmodule Dialup.Contexts do
  @moduledoc """
  Declarative bounded-context map for Dialup Commanded applications.

      defmodule MyApp.Contexts do
        use Dialup.Contexts

        context :ordering do
          commanded_context MyApp.Ordering
          aggregates [MyApp.Ordering.Aggregates.Order]
          events_out [:OrderConfirmed]
          events_in [:PaymentCompleted]
        end
      end
  """

  defmacro __using__(_opts) do
    quote do
      import Dialup.Contexts,
        only: [context: 2, commanded_context: 1, aggregates: 1, events_out: 1, events_in: 1]

      Module.register_attribute(__MODULE__, :dialup_contexts, accumulate: true)
      Module.register_attribute(__MODULE__, :dialup_current_context, accumulate: false)
      @before_compile Dialup.Contexts
    end
  end

  defmacro context(name, do: block) do
    quote do
      @dialup_current_context %{
        name: unquote(name),
        commanded_context: nil,
        aggregates: [],
        events_out: [],
        events_in: []
      }

      unquote(block)

      @dialup_contexts @dialup_current_context
    end
  end

  defmacro commanded_context(module) do
    quote do
      @dialup_current_context Map.put(
                                @dialup_current_context,
                                :commanded_context,
                                unquote(module)
                              )
    end
  end

  defmacro aggregates(modules) do
    quote do
      @dialup_current_context Map.put(@dialup_current_context, :aggregates, unquote(modules))
    end
  end

  defmacro events_out(events) do
    quote do
      @dialup_current_context Map.put(@dialup_current_context, :events_out, unquote(events))
    end
  end

  defmacro events_in(events) do
    quote do
      @dialup_current_context Map.put(@dialup_current_context, :events_in, unquote(events))
    end
  end

  defmacro __before_compile__(env) do
    contexts = Module.get_attribute(env.module, :dialup_contexts, []) |> Enum.reverse()
    validate_event_consistency!(env, contexts)

    quote do
      def __dialup_contexts__, do: unquote(Macro.escape(contexts))
    end
  end

  @doc false
  def validate_event_consistency!(env, contexts) do
    all_out =
      contexts
      |> Enum.flat_map(& &1.events_out)
      |> MapSet.new()

    Enum.each(contexts, fn ctx ->
      orphans = Enum.reject(ctx.events_in, &MapSet.member?(all_out, &1))

      if orphans != [] do
        IO.warn(
          "context #{inspect(ctx.name)}: events_in #{inspect(orphans)} " <>
            "are not produced by any declared context",
          Macro.Env.stacktrace(env)
        )
      end
    end)
  end

  @doc false
  def load_contexts do
    :code.all_loaded()
    |> Enum.filter(fn {mod, _} -> function_exported?(mod, :__dialup_contexts__, 0) end)
    |> Enum.flat_map(fn {mod, _} -> mod.__dialup_contexts__() end)
  end

  @doc false
  def find_context(module, contexts) do
    module_str = to_string(module)

    Enum.find_value(contexts, fn ctx ->
      cond do
        ctx.commanded_context &&
            (module_str == to_string(ctx.commanded_context) or
               String.starts_with?(module_str, to_string(ctx.commanded_context) <> ".")) ->
          ctx.name

        Enum.any?(ctx.aggregates, fn agg ->
          agg_str = to_string(agg)
          module_str == agg_str or String.starts_with?(module_str, agg_str <> ".")
        end) ->
          ctx.name

        true ->
          nil
      end
    end)
  end

  @doc false
  def generate_mermaid(contexts) do
    subgraphs =
      Enum.map(contexts, fn ctx ->
        aggregates =
          ctx.aggregates
          |> Enum.map(fn mod ->
            name = mod |> Module.split() |> List.last()
            "    #{name}"
          end)
          |> Enum.join("\n")

        ctx_label = ctx.name |> to_string() |> Macro.camelize()
        "  subgraph #{ctx_label}\n#{aggregates}\n  end"
      end)
      |> Enum.join("\n")

    edges =
      Enum.flat_map(contexts, fn producer ->
        Enum.flat_map(producer.events_out, fn event ->
          consumers = Enum.filter(contexts, fn consumer -> event in consumer.events_in end)

          Enum.map(consumers, fn consumer ->
            p = producer.name |> to_string() |> Macro.camelize()
            c = consumer.name |> to_string() |> Macro.camelize()
            "  #{p} -- \"#{event}\" --> #{c}"
          end)
        end)
      end)
      |> Enum.join("\n")

    "flowchart LR\n#{subgraphs}\n#{edges}\n"
  end
end
