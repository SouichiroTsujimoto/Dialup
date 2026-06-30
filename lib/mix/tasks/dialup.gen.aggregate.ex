defmodule Mix.Tasks.Dialup.Gen.Aggregate do
  @moduledoc """
  Generates Commanded aggregate scaffolding for a Dialup application.

      mix dialup.gen.aggregate ContextName AggregateName table_name \\
          command1:field1:type,field2:type \\
          command2

  ## Examples

      mix dialup.gen.aggregate Ordering Order orders \\
          add_item:product_id:string,qty:integer,price:integer \\
          confirm

  ## Options

    * `--app` — OTP application name (defaults to `Mix.Project` app)
    * `--force` — overwrite existing files (except `commanded_app.ex`, which is always skipped)
  """

  use Mix.Task

  @shortdoc "Generates Commanded aggregate scaffolding"

  @switches [app: :string, force: :boolean]
  @aliases [f: :force]

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("compile")

    {opts, positional} = OptionParser.parse!(args, strict: @switches, aliases: @aliases)

    case positional do
      [context, aggregate, table | commands] when commands != [] ->
        generate(context, aggregate, table, commands, opts)

      _ ->
        Mix.raise("""
        mix dialup.gen.aggregate expects at least:

            mix dialup.gen.aggregate Context Aggregate table command[:fields...]

        Example:

            mix dialup.gen.aggregate Ordering Order orders add_item:sku:string confirm
        """)
    end
  end

  def parse_command(spec) when is_binary(spec) do
    case String.split(spec, ":", parts: 2) do
      [name] ->
        %{name: name, fields: []}

      [name, fields_spec] ->
        fields =
          fields_spec
          |> String.split(",", trim: true)
          |> Enum.map(&parse_field/1)

        %{name: name, fields: fields}
    end
  end

  def parse_field(spec) do
    case String.split(spec, ":", parts: 2) do
      [name, type] -> %{name: name, type: String.to_atom(type)}
      [_name] -> Mix.raise("invalid field spec #{inspect(spec)}; expected name:type")
    end
  end

  def derive_event_name(command_name) when is_binary(command_name) do
    parts = String.split(command_name, "_")

    case parts do
      [verb] ->
        past_tense(verb) |> Macro.camelize()

      [verb | nouns] ->
        noun_part = nouns |> Enum.map(&Macro.camelize/1) |> Enum.join()
        noun_part <> Macro.camelize(past_tense(verb))
    end
  end

  def past_tense("add"), do: "added"
  def past_tense("create"), do: "created"
  def past_tense("confirm"), do: "confirmed"
  def past_tense("cancel"), do: "cancelled"
  def past_tense("remove"), do: "removed"
  def past_tense("update"), do: "updated"
  def past_tense("delete"), do: "deleted"
  def past_tense("increment"), do: "incremented"
  def past_tense("decrement"), do: "decremented"
  def past_tense(verb), do: verb <> "ed"

  def ecto_type(:string), do: "string"
  def ecto_type(:integer), do: "integer"
  def ecto_type(:number), do: "float"
  def ecto_type(:boolean), do: "boolean"
  def ecto_type(type) when is_atom(type), do: to_string(type)

  def migration_type(:string), do: "string"
  def migration_type(:integer), do: "integer"
  def migration_type(:number), do: "float"
  def migration_type(:boolean), do: "boolean"
  def migration_type(type) when is_atom(type), do: to_string(type)

  defp generate(context, aggregate, table, command_specs, opts) do
    otp_app = opts[:app] || app_name!()
    app_module = otp_app |> to_string() |> Macro.camelize()
    context_name = Macro.camelize(context)
    aggregate_name = Macro.camelize(aggregate)
    commands = command_specs |> Enum.map(&parse_command/1) |> enrich_commands()

    all_fields =
      commands
      |> Enum.flat_map(& &1.fields)
      |> Enum.uniq_by(& &1.name)

    bindings = [
      otp_app: otp_app,
      app_module: app_module,
      app_module_str: module_str(app_module),
      base_mod: module_str(app_module),
      context_name: context_name,
      context_module: Module.concat([app_module, context_name]),
      context_mod: module_str(Module.concat([app_module, context_name])),
      context_path: context |> Macro.underscore(),
      aggregate_name: aggregate_name,
      agg_name: aggregate_name,
      aggregate_module: Module.concat([app_module, context_name, Aggregates, aggregate_name]),
      aggregate_mod:
        module_str(Module.concat([app_module, context_name, Aggregates, aggregate_name])),
      agg_mod:
        module_str(Module.concat([app_module, context_name, Aggregates, aggregate_name])),
      aggregate_underscore: Macro.underscore(aggregate_name),
      table_name: table,
      commands: commands,
      all_unique_fields: all_fields,
      migration_timestamp: next_migration_timestamp()
    ]

    force? = Keyword.get(opts, :force, false)
    base = "lib/#{otp_app}/#{bindings[:context_path]}"

    static_files = [
      {"context.ex", Path.join(base, "#{bindings[:context_path]}.ex")},
      {"aggregate.ex", Path.join(base, "aggregates/#{bindings[:aggregate_underscore]}.ex")},
      {"projector.ex", Path.join(base, "projectors/#{bindings[:aggregate_underscore]}_summary.ex")},
      {"projection.ex",
       Path.join(base, "projections/#{bindings[:aggregate_underscore]}_summary.ex")},
      {"commanded_app.ex", "lib/#{otp_app}/commanded_app.ex"},
      {"migration.ex",
       "priv/repo/migrations/#{bindings[:migration_timestamp]}_create_#{table}.exs"}
    ]

    for {template, dest} <- static_files do
      write_template(template, dest, bindings, force?)
    end

    for cmd <- commands do
      cmd_path = Macro.underscore(cmd.name)
      event_path = Macro.underscore(cmd.event_module)

      write_template(
        "command.ex",
        Path.join(base, "commands/#{cmd_path}.ex"),
        Keyword.merge(bindings,
          command: cmd,
          command_module: Macro.camelize(cmd.name),
          cmd_mod: Macro.camelize(cmd.name),
          event_mod: cmd.event_module
        ),
        force?
      )

      write_template(
        "event.ex",
        Path.join(base, "events/#{event_path}.ex"),
        Keyword.merge(bindings, command: cmd, event_module: cmd.event_module, event_mod: cmd.event_module),
        force?
      )
    end

    :ok
  end

  defp enrich_commands(commands) do
    Enum.map(commands, fn cmd ->
      Map.put(cmd, :event_module, derive_event_name(cmd.name))
    end)
  end

  defp write_template(template, dest, bindings, force?) do
    cond do
      template == "commanded_app.ex" and File.exists?(dest) ->
        Mix.shell().info("* skipping #{dest} (already exists)")

      File.exists?(dest) and not force? ->
        Mix.raise("Refusing to overwrite #{dest}. Pass --force to overwrite.")

      true ->
        source = template_path(template)
        content = EEx.eval_file(source, bindings, trim: true)
        File.mkdir_p!(Path.dirname(dest))
        File.write!(dest, content)
        Mix.shell().info("* creating #{dest}")
    end
  end

  defp app_name! do
    Mix.Project.config()[:app] ||
      Mix.raise("Could not determine OTP app. Pass --app APP_NAME.")
  end

  defp next_migration_timestamp do
    migrations_dir = Path.join(File.cwd!(), "priv/repo/migrations")
    base = utc_timestamp()

    if File.exists?(migrations_dir) do
      max_existing =
        migrations_dir
        |> File.ls!()
        |> Enum.filter(&String.match?(&1, ~r/^\d{14}_/))
        |> Enum.map(&String.slice(&1, 0, 14))
        |> Enum.max(fn -> base end)

      if max_existing >= base do
        increment_timestamp(max_existing)
      else
        base
      end
    else
      base
    end
  end

  defp utc_timestamp do
    {{y, m, d}, {h, min, s}} = :calendar.universal_time()
    Enum.map([y, m, d, h, min, s], &pad/1) |> Enum.join()
  end

  defp increment_timestamp(ts) when is_binary(ts) do
    {n, _} = Integer.parse(ts)
    pad_number(n + 1)
  end

  defp pad_number(n), do: n |> Integer.to_string() |> String.pad_leading(14, "0")

  defp pad(n) when n < 10, do: "0#{n}"
  defp pad(n), do: to_string(n)

  defp module_str(module) do
    module
    |> inspect()
    |> String.replace_prefix("Elixir.", "")
  end

  defp template_path(name) do
    priv_dir =
      case :code.priv_dir(:dialup) do
        {:error, :bad_name} ->
          __ENV__.file
          |> Path.dirname()
          |> Path.join("../../../priv")
          |> Path.expand()

        dir ->
          dir
      end

    Path.join(priv_dir, "templates/dialup.gen.aggregate/#{name}.eex")
  end
end
