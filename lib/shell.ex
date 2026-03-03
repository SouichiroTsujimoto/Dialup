defmodule Dialup.Shell do
  import Phoenix.HTML, only: [raw: 1]

  @template Path.join([__DIR__, "..", "priv", "templates", "root.html.heex"])
            |> Path.expand()
  @external_resource @template

  @source File.read!(@template)

  defp render_template(assigns) do
    unquote(
      EEx.compile_string(@source,
        engine: Phoenix.LiveView.TagEngine,
        line: 1,
        file: @template,
        caller: __ENV__,
        source: @source,
        tag_handler: Phoenix.LiveView.HTMLEngine
      )
    )
  end

  def render(assigns) do
    render_template(assigns)
    |> Phoenix.HTML.Safe.to_iodata()
    |> IO.iodata_to_binary()
  end
end
