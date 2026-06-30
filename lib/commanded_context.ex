defmodule Dialup.CommandedContext do
  @moduledoc """
  Application-service facade for Commanded bounded contexts.

  Use in a context module:

      defmodule MyApp.Ordering do
        use Dialup.CommandedContext, app: MyApp.CommandedApp

        alias MyApp.Ordering.Commands.AddItem
      end

  Dispatches default to `consistency: :strong` so read models are up to date
  before the page remounts.
  """

  defmacro __using__(opts) do
    app = Keyword.fetch!(opts, :app)

    quote do
      @commanded_app unquote(app)

      @doc """
      Dispatches a command to the configured Commanded application.
      """
      def dispatch(command, opts \\ []) do
        unquote(app).dispatch(command, Keyword.put_new(opts, :consistency, :strong))
      end
    end
  end
end
