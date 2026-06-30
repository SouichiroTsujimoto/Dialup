defmodule Mix.Tasks.Compile.DialupContexts do
  @moduledoc false
  use Mix.Task.Compiler

  @impl Mix.Task.Compiler
  def run(_args) do
    existing = Code.get_compiler_option(:tracers) || []

    unless Dialup.Contexts.Tracer in existing do
      Code.put_compiler_option(:tracers, existing ++ [Dialup.Contexts.Tracer])
    end

    {:ok, []}
  end

  @impl Mix.Task.Compiler
  def manifests, do: []
end
