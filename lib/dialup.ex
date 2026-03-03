defmodule Dialup do
  # use Application

  defmacro __using__(opts) do
    app_dir = Keyword.fetch!(opts, :app_dir)
    title = Keyword.get(opts, :title, "Dialup App")
    lang = Keyword.get(opts, :lang, "en")
    head_extra = Keyword.get(opts, :head_extra, "")

    quote do
      use Dialup.Router, app_dir: unquote(app_dir)

      def __shell_opts__ do
        %{title: unquote(title), lang: unquote(lang), head_extra: unquote(head_extra)}
      end
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

    children = [
      {Bandit, plug: {Dialup.Server, app: app_module}, port: port}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: __MODULE__)
  end

  # @impl Application
  # def start(_type, _args) do
  #   children = [
  #     {Bandit, plug: Dialup.Server, port: 8080}
  #   ]

  #   opts = [strategy: :one_for_one, name: Dialup.Supervisor]
  #   Supervisor.start_link(children, opts)
  # end
end
