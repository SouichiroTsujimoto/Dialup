defmodule Dialup.Layout do
  @callback render(assigns :: map()) :: Phoenix.LiveView.Rendered.t() | binary()

  defmacro __using__(_opts) do
    quote do
      @behaviour Dialup.Layout

      import Phoenix.Component
      import Phoenix.HTML, only: [raw: 1]

      @before_compile Dialup.Layout
    end
  end

  defmacro __before_compile__(env) do
    unless Module.defines?(env.module, {:render, 1}) do
      raise CompileError,
        file: env.file,
        line: env.line,
        description: "module #{inspect(env.module)} using Dialup.Layout must define render/1"
    end
  end
end
