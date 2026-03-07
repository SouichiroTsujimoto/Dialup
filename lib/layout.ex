defmodule Dialup.Layout do
  @callback render(assigns :: map()) :: Phoenix.LiveView.Rendered.t()

  # session :: 親レイアウトが設定したsession（rootレイアウトは %{} を受け取る）
  @callback mount(session :: map()) :: {:ok, map()}

  @optional_callbacks mount: 1

  defmacro __using__(_opts) do
    quote do
      @behaviour Dialup.Layout

      import Phoenix.Component
      import Phoenix.HTML, only: [raw: 1]
      import Dialup.Page, only: [overwrite: 2, set_default: 2]

      # デフォルト実装：何もしない（mountを定義しないlayoutはsessionに何も追加しない）
      def mount(session), do: {:ok, session}
      defoverridable mount: 1

      @before_compile Dialup.Layout
    end
  end

  defmacro __before_compile__(env) do
    template_path = env.file |> Path.rootname(".ex") |> Kernel.<>(".html.heex")
    has_render = Module.defines?(env.module, {:render, 1})
    has_template = File.exists?(template_path)

    cond do
      has_render ->
        :ok

      has_template ->
        source = File.read!(template_path)

        compiled =
          EEx.compile_string(source,
            engine: Phoenix.LiveView.TagEngine,
            line: 1,
            file: template_path,
            caller: __CALLER__,
            source: source,
            tag_handler: Phoenix.LiveView.HTMLEngine
          )

        quote do
          @external_resource unquote(template_path)

          def render(assigns) do
            _ = assigns
            unquote(compiled)
          end
        end

      true ->
        raise CompileError,
          file: env.file,
          line: env.line,
          description:
            "#{inspect(env.module)} must define render/1 or provide #{Path.basename(template_path)}"
    end
  end
end
