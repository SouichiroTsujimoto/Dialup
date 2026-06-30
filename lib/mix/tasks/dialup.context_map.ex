defmodule Mix.Tasks.Dialup.ContextMap do
  @moduledoc """
  Generates a Mermaid context map from `Dialup.Contexts` declarations.

      mix dialup.context_map

  Writes `context_map.mmd` in the current working directory.
  """

  use Mix.Task

  @shortdoc "Generates a Mermaid context map from Dialup.Contexts declarations"

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("compile")

    contexts = Dialup.Contexts.load_contexts()

    if contexts == [] do
      Mix.raise(
        "No modules exporting __dialup_contexts__/0 were found. Define one with use Dialup.Contexts."
      )
    end

    mermaid = Dialup.Contexts.generate_mermaid(contexts)
    path = "context_map.mmd"
    File.write!(path, mermaid)
    Mix.shell().info("Context map written to #{path}")
    Mix.shell().info("\n#{mermaid}")
  end
end
