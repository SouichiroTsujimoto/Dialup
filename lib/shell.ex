defmodule Dialup.Shell do
  @moduledoc false

  @framework_template Path.join([__DIR__, "..", "priv", "templates", "root.html.heex"])
                      |> Path.expand()

  defmacro __before_compile__(env) do
    template_path = Module.get_attribute(env.module, :_dialup_shell_path)

    path =
      if template_path && File.exists?(template_path) do
        template_path
      else
        @framework_template
      end

    source = File.read!(path)

    quote do
      import Phoenix.HTML, only: [raw: 1]

      require EEx

      EEx.function_from_string(
        :defp,
        :__render_shell_template__,
        unquote(source),
        [:assigns],
        engine: Phoenix.LiveView.TagEngine,
        tag_handler: Phoenix.LiveView.HTMLEngine,
        caller: __ENV__,
        file: unquote(path),
        source: unquote(source)
      )

      def __render_shell__(assigns) do
        __render_shell_template__(assigns)
        |> Phoenix.HTML.Safe.to_iodata()
        |> IO.iodata_to_binary()
      end
    end
  end
end
