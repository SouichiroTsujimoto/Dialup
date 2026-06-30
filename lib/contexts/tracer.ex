defmodule Dialup.Contexts.Tracer do
  @moduledoc false

  def trace({:remote_function, meta, module, _name, _arity}, env) do
    check_cross_context(env.module, module, meta, env)
    :ok
  end

  def trace({:remote_macro, meta, module, _name, _arity}, env) do
    check_cross_context(env.module, module, meta, env)
    :ok
  end

  def trace({:struct_expansion, meta, module, _keys}, env) do
    check_cross_context(env.module, module, meta, env)
    :ok
  end

  def trace(_event, _env), do: :ok

  defp check_cross_context(caller, callee, meta, env) do
    contexts = Dialup.Contexts.load_contexts()

    if contexts != [] do
      caller_ctx = Dialup.Contexts.find_context(caller, contexts)
      callee_ctx = Dialup.Contexts.find_context(callee, contexts)

      if caller_ctx && callee_ctx && caller_ctx != callee_ctx do
        callee_def = Enum.find(contexts, &(&1.name == callee_ctx))

        unless callee == callee_def.commanded_context do
          line = meta[:line] || env.line

          IO.warn(
            "#{inspect(caller)} directly references #{inspect(callee)} " <>
              "in context #{inspect(callee_ctx)}. " <>
              "Cross-context access must go through the public API " <>
              "(#{inspect(callee_def.commanded_context)}).",
            [{env.file, line}]
          )
        end
      end
    end
  end
end
