defmodule Dialup.Error do
  @moduledoc """
  エラーページのビヘイビア。`render/2` でステータスコードごとに表示を分岐する。
  layout と同様にディレクトリ階層で継承される。
  """

  @callback render(status :: integer(), assigns :: map()) :: Phoenix.LiveView.Rendered.t()

  defmacro __using__(_opts) do
    quote do
      @behaviour Dialup.Error

      import Phoenix.Component
      import Phoenix.HTML, only: [raw: 1]

      @layout true

      @before_compile Dialup.Error
    end
  end

  defmacro __before_compile__(env) do
    use_layout = Module.get_attribute(env.module, :layout, true)

    css_path = env.file |> Path.rootname(".ex") |> Kernel.<>(".css")

    css_quote =
      if File.exists?(css_path) do
        css_content = File.read!(css_path)

        scope_class =
          "d-" <>
            (env.module
             |> Atom.to_string()
             |> :erlang.md5()
             |> Base.encode16(case: :lower)
             |> binary_part(0, 7))

        scoped_css = ".#{scope_class} {\n#{css_content}\n}"

        quote do
          @external_resource unquote(css_path)
          def __css__, do: unquote(scoped_css)
          def __css_scope__, do: unquote(scope_class)
        end
      else
        quote do
          def __css__, do: nil
          def __css_scope__, do: nil
        end
      end

    quote do
      def __layout__, do: unquote(use_layout)
      unquote(css_quote)
    end
  end
end
