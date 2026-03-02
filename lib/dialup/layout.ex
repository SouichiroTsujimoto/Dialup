defmodule Dialup.Layout do
  @moduledoc """
  Dialup レイアウトモジュールの基底マクロ。

  ## 使い方

      defmodule Dialup.App.Layout do
        use Dialup.Layout

        def render(assigns) do
          ~H\"\"\"
          <div>
            <nav>...</nav>
            <main>{raw(assigns[:inner_content])}</main>
          </div>
          \"\"\"
        end
      end

  ## inner_content について

  `assigns[:inner_content]` には子ページまたは子レイアウトが
  レンダリングした HTML 文字列が入る。
  サーバー生成の信頼済み HTML なので `raw/1` で展開する。
  """

  defmacro __using__(_opts) do
    quote do
      import Phoenix.Component
      import Phoenix.HTML, only: [raw: 1]
    end
  end
end
