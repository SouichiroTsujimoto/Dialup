defmodule Dialup.Page do
  @callback render(assigns :: map()) :: Phoenix.LiveView.Rendered.t() | binary()
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
    unless Module.defines?(env.module, {:render, 1}) do
      raise CompileError,
        file: env.file,
        line: env.line,
        description: "module #{inspect(env.module)} using Dialup.Page must define render/1"
    end
  end
end
