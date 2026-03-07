defmodule Dialup.Page do
  @callback render(assigns :: map()) :: Phoenix.LiveView.Rendered.t()

  # params: URLパラメータ
  # assigns: session の内容（current_user 等を読み取り可能）
  # 返り値の map が page assigns になる（session キーは自動的に除外される）
  @callback mount(params :: map(), assigns :: map()) :: {:ok, map()}
  @callback mount(assigns :: map()) :: {:ok, map()}

  # 再描画なし（状態のみ更新）
  @callback handle_event(event :: binary(), value :: any(), assigns :: map()) ::
              {:noreply, map()}
              | {:update, map()}
              | {:patch, target :: binary(), rendered :: any(), map()}

  @callback handle_info(msg :: any(), assigns :: map()) ::
              {:noreply, map()}
              | {:update, map()}
              | {:patch, target :: binary(), rendered :: any(), map()}

  # mount/1, handle_info はオプショナル
  @optional_callbacks mount: 1, handle_info: 2

  def overwrite(assigns, overwrite) when is_map(assigns) and is_map(overwrite) do
    Map.merge(assigns, overwrite)
  end

  def set_default(assigns, defaults) when is_map(assigns) and is_map(defaults) do
    Map.merge(defaults, assigns)
  end

  defmacro __using__(_opts) do
    quote do
      @behaviour Dialup.Page

      import Phoenix.Component
      import Phoenix.HTML, only: [raw: 1]

      # ローカルでの使用も可能に（import）
      import Dialup.Page, only: [overwrite: 2, set_default: 2]

      # デフォルト実装
      def handle_event(_event, _value, assigns), do: {:noreply, assigns}
      def handle_info(_msg, assigns), do: {:noreply, assigns}

      defoverridable handle_event: 3, handle_info: 2

      @before_compile Dialup.Page
    end
  end

  defmacro __before_compile__(env) do
    template_path = env.file |> Path.rootname(".ex") |> Kernel.<>(".html.heex")
    has_render = Module.defines?(env.module, {:render, 1})
    has_template = File.exists?(template_path)

    # mount/1 と mount/2 の定義をチェック
    has_mount_1 = Module.defines?(env.module, {:mount, 1})
    has_mount_2 = Module.defines?(env.module, {:mount, 2})

    # mount関数の生成
    mount_quote =
      cond do
        has_mount_2 ->
          quote do
            # mount/2 が定義済み
          end

        # mount/2 ラッパーを生成
        has_mount_1 and not has_mount_2 ->
          quote do
            def mount(_params, assigns) do
              mount(assigns)
            end
          end

        # デフォルトの mount/2 を生成
        true ->
          quote do
            def mount(_params, assigns), do: {:ok, assigns}
          end
      end

    # テンプレート用のrender関数
    render_quote =
      cond do
        has_render ->
          quote do
            # render/1 が定義済み
          end

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

    # 両方のコードを結合して返す
    quote do
      unquote(mount_quote)
      unquote(render_quote)
    end
  end
end
