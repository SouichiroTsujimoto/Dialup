defmodule Mix.Tasks.Dialup.New do
  @moduledoc """
  Creates a new Dialup project.

  It expects the path of the project as an argument.

      mix dialup.new PATH [--app APP_NAME] [--module MODULE_NAME]

  A project at the given PATH will be created with:

    * config/config.exs - Basic configuration
    * lib/APP_NAME.ex - Application entry point
    * lib/APP_NAME/layout.ex - Root layout
    * lib/APP_NAME/page.ex - Home page at /
    * mix.exs - Mix project configuration
    * README.md - Project documentation
    * .gitignore - Git ignore patterns

  ## Options

    * `--app APP_NAME` - The OTP application name (defaults to PATH basename)
    * `--module MODULE_NAME` - The base module name (defaults to camelized PATH)

  ## Examples

      mix dialup.new hello_world
      mix dialup.new my_app --app my_custom_app
      mix dialup.new my_app --module MyCustomModule

  """

  use Mix.Task

  @version Mix.Project.config()[:version]

  @switches [
    app: :string,
    module: :string
  ]

  @impl Mix.Task
  def run(args) do
    case OptionParser.parse!(args, strict: @switches) do
      {opts, [path]} ->
        generate(path, opts)

      {_opts, []} ->
        Mix.raise("""
        mix dialup.new expects a path to be given.

        Examples:
            mix dialup.new hello_world
            mix dialup.new my_app --app my_custom_app
        """)

      {_opts, _} ->
        Mix.raise("""
        mix dialup.new expects a single path argument.
        If you want to pass multiple arguments, use --app or --module options.
        """)
    end
  end

  defp generate(path, opts) do
    target_dir = Path.expand(path)

    if File.exists?(target_dir) and not Enum.empty?(File.ls!(target_dir)) do
      Mix.raise("""
      The target directory "#{target_dir}" already exists and is not empty.
      Please choose a different path or delete the existing directory first.
      """)
    end

    app = opts[:app] || Path.basename(target_dir) |> String.downcase() |> String.replace(~r/[^a-z0-9_]/, "_")
    mod = opts[:module] || Macro.camelize(app)

    bindings = [
      app: app,
      mod: mod,
      dialup_version: @version
    ]

    File.mkdir_p!(target_dir)

    for {template_name, dest_path} <- template_mappings(app) do
      source = template_path(template_name)
      dest = Path.join(target_dir, dest_path)

      content = EEx.eval_file(source, bindings, trim: true)

      File.mkdir_p!(Path.dirname(dest))
      File.write!(dest, content)
    end

    # Run mix format to fix indentation warnings
    Mix.shell().info("Formatting files...")
    System.cmd("mix", ["format"], cd: target_dir, stderr_to_stdout: true)

    Mix.shell().info("""

    Your Dialup project was created successfully.

    To get started:

        cd #{path}
        mix deps.get
        mix run --no-halt

    Then visit http://localhost:4000
    """)
  end

  defp template_path(name) do
    # Support both installed package and local development
    priv_dir =
      case :code.priv_dir(:dialup) do
        {:error, :bad_name} ->
          # Local development - find templates relative to this file
          __ENV__.file
          |> Path.dirname()
          |> Path.join("../../../priv")
          |> Path.expand()

        dir ->
          dir
      end

    Path.join(priv_dir, "templates/dialup.new/#{name}.eex")
  end

  defp template_mappings(app) do
    app_string = to_string(app)

    [
      {"mix.exs", "mix.exs"},
      {"README.md", "README.md"},
      {"gitignore", ".gitignore"},
      {"formatter.exs", ".formatter.exs"},
      {"app.ex", "lib/#{app_string}.ex"},
      {"layout.ex", "lib/app/layout.ex"},
      {"page.ex", "lib/app/page.ex"}
    ]
  end
end
