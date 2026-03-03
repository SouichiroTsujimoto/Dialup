defmodule Dialup.Page do
  @callback render(assigns :: map()) :: Phoenix.LiveView.Rendered.t()
  @callback mount(assigns :: map()) :: {:ok, map()}
  # 再描画なし（状態のみ更新）
  @callback handle_event(event :: binary(), value :: any(), assigns :: map()) ::
              {:noreply, map()}
              # 全体再描画
              | {:update, map()}
              # 部分re-render（target: DOM要素のid、rendered: ~H または binary）
              | {:patch, target :: binary(), rendered :: any(), map()}

  defmacro __using__(_opts) do
    quote do
      @behaviour Dialup.Page

      import Phoenix.Component
      import Phoenix.HTML, only: [raw: 1]

      def mount(assigns), do: {:ok, assigns}
      def handle_event(_event, _value, assigns), do: {:noreply, assigns}

      defoverridable mount: 1, handle_event: 3

      @before_compile Dialup.Page
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
