defmodule Dialup do
  defmacro __using__(opts) do
    app_dir = Keyword.fetch!(opts, :app_dir)
    title = Keyword.get(opts, :title, "Dialup App")
    lang = Keyword.get(opts, :lang, "en")
    plugs = Keyword.get(opts, :plugs, [])
    session_store = Keyword.get(opts, :session_store, :memory)

    quote do
      use Dialup.Router, app_dir: unquote(app_dir)

      # app_dir は __DIR__ <> "/app" のため quote 内で評価（ユーザモジュールのコンパイル時に __DIR__ が展開される）
      @_dialup_static_dir (unquote(app_dir)
                           |> Path.dirname()
                           |> Path.dirname()
                           |> Path.join("priv/static"))

      for f <- ~w[dialup.js idiomorph.js] do
        if File.exists?(Path.join(@_dialup_static_dir, f)) do
          IO.warn(
            "priv/static/#{f} shadows the Dialup framework file. Remove it unless intentional.",
            []
          )
        end
      end

      @_dialup_shell_path (unquote(app_dir) |> Path.dirname() |> Path.join("root.html.heex"))
      @external_resource @_dialup_shell_path
      @before_compile Dialup.Shell

      def __shell_opts__, do: %{title: unquote(title), lang: unquote(lang)}
      def __static_dir__, do: @_dialup_static_dir
      def __plugs__, do: unquote(Macro.escape(plugs))
      def __session_store__, do: unquote(session_store)
      def __check_origin__, do: unquote(Keyword.get(opts, :check_origin, :conn))
    end
  end

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor
    }
  end

  def start_link(opts) do
    app_module = Keyword.fetch!(opts, :app)
    port = Keyword.get(opts, :port, 4000)

    session_store =
      if function_exported?(app_module, :__session_store__, 0),
        do: app_module.__session_store__(),
        else: :memory

    store_children =
      if session_store == :ets, do: [Dialup.SessionStore], else: []

    base_children =
      store_children ++
        [
          {Registry, keys: :unique, name: Dialup.SessionRegistry},
          {DynamicSupervisor, name: Dialup.SessionSupervisor, strategy: :one_for_one},
          {Bandit, plug: {Dialup.Server, app: app_module}, port: port}
        ]

    children =
      if Code.ensure_loaded?(Mix) and Mix.env() == :dev do
        [{Dialup.Reloader, [Path.join(File.cwd!(), "lib")]} | base_children]
      else
        base_children
      end

    Supervisor.start_link(children, strategy: :one_for_one, name: __MODULE__)
  end
end
