defmodule Dialup.Page do
  @moduledoc """
  Dialup ページモジュールの基底マクロ。

  ## 使い方

      defmodule Dialup.App.Root do
        use Dialup.Page

        def render(assigns) do
          ~H\"\"\"
          <div>Hello, {@name}!</div>
          \"\"\"
        end
      end

  ## 提供されるもの

  - `~H` シジル（HEEx テンプレート・自動エスケープ）
  - `raw/1`（信頼済みHTMLをエスケープなしで出力）
  - `mount/1` と `handle_event/3` のデフォルト実装（オーバーライド可能）
  """

  defmacro __using__(_opts) do
    quote do
      import Phoenix.Component
      import Phoenix.HTML, only: [raw: 1]

      # デフォルト実装（定義しなくても動く）
      def mount(assigns), do: {:ok, assigns}
      def handle_event(_event, _value, assigns), do: {:noreply, assigns}

      # ページ側でオーバーライドできる
      defoverridable mount: 1, handle_event: 3
    end
  end
end
