defmodule Dialup.GenAggregateTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Dialup.Gen.Aggregate, as: Gen

  test "parse_command/1 parses field specs" do
    assert Gen.parse_command("confirm") == %{name: "confirm", fields: []}

    assert Gen.parse_command("add_item:product_id:string,qty:integer") == %{
             name: "add_item",
             fields: [
               %{name: "product_id", type: :string},
               %{name: "qty", type: :integer}
             ]
           }
  end

  test "derive_event_name/1 maps verbs to past-tense event modules" do
    assert Gen.derive_event_name("add_item") == "ItemAdded"
    assert Gen.derive_event_name("confirm") == "Confirmed"
    assert Gen.derive_event_name("confirm_order") == "OrderConfirmed"
  end

  test "command template renders a defstruct command module" do
    bindings = sample_bindings()

    content =
      EEx.eval_file(
        template_path("command.ex"),
        Keyword.merge(bindings,
          command: %{name: "add_item", fields: [%{name: "sku", type: :string}]},
          command_module: "AddItem",
          cmd_mod: "AddItem"
        ),
        trim: true
      )

    assert content =~ "defmodule MyApp.Ordering.Commands.AddItem"
    assert content =~ "defstruct [:sku]"
  end

  test "aggregate template renders execute/apply clauses" do
    bindings = sample_bindings()

    content = EEx.eval_file(template_path("aggregate.ex"), bindings, trim: true)

    assert content =~ "defmodule MyApp.Ordering.Aggregates.Order"
    assert content =~ "Commands.AddItem"
    assert content =~ "Events.ItemAdded"
  end

  test "migration template uses the table name" do
    bindings = sample_bindings()

    content = EEx.eval_file(template_path("migration.ex"), bindings, trim: true)

    assert content =~ "create table(:orders)"
    assert content =~ "add :sku, :string"
  end

  defp sample_bindings do
    commands = [
      %{
        name: "add_item",
        fields: [%{name: "sku", type: :string}],
        event_module: "ItemAdded"
      },
      %{name: "confirm", fields: [], event_module: "Confirmed"}
    ]

    [
      otp_app: :my_app,
      app_module: MyApp,
      app_module_str: "MyApp",
      base_mod: "MyApp",
      context_name: "Ordering",
      context_module: MyApp.Ordering,
      context_mod: "MyApp.Ordering",
      context_path: "ordering",
      aggregate_name: "Order",
      agg_name: "Order",
      aggregate_module: MyApp.Ordering.Aggregates.Order,
      aggregate_mod: "MyApp.Ordering.Aggregates.Order",
      agg_mod: "MyApp.Ordering.Aggregates.Order",
      aggregate_underscore: "order",
      table_name: "orders",
      commands: commands,
      all_unique_fields: [%{name: "sku", type: :string}],
      migration_timestamp: "20260629120000"
    ]
  end

  defp template_path(name) do
    Path.join([Path.expand("../priv", __DIR__), "templates/dialup.gen.aggregate/#{name}.eex"])
  end
end
