defmodule Dialup do
  defmacro __using__(opts) do
    app_dir = Keyword.fetch!(opts, :app_dir)
    title = Keyword.get(opts, :title, "Dialup App")
    lang = Keyword.get(opts, :lang, "en")
    head_extra = Keyword.get(opts, :head_extra, "")
    plugs = Keyword.get(opts, :plugs, [])
    session_store = Keyword.get(opts, :session_store, :memory)

    quote do
      use Dialup.Router, app_dir: unquote(app_dir)

      def __shell_opts__ do
        %{title: unquote(title), lang: unquote(lang), head_extra: unquote(head_extra)}
      end

      def __plugs__, do: unquote(Macro.escape(plugs))
      def __session_store__, do: unquote(session_store)
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
