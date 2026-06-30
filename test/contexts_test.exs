defmodule Dialup.ContextsTest do
  use ExUnit.Case, async: true

  alias Dialup.Contexts
  alias Dialup.ContextsTest.Contexts, as: TestContexts

  test "__dialup_contexts__/0 returns declared contexts" do
    contexts = TestContexts.__dialup_contexts__()

    assert length(contexts) == 2

    ordering = Enum.find(contexts, &(&1.name == :ordering))
    assert ordering.commanded_context == Dialup.ContextsTest.Ordering
    assert ordering.events_out == [:OrderConfirmed]
    assert ordering.events_in == [:PaymentCompleted]
  end

  test "validate_event_consistency!/2 warns about orphan events_in" do
    contexts = [
      %{
        name: :consumer,
        commanded_context: nil,
        aggregates: [],
        events_out: [],
        events_in: [:MissingEvent]
      }
    ]

    output =
      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        Contexts.validate_event_consistency!(__ENV__, contexts)
      end)

    assert output =~ "MissingEvent"
    assert output =~ "consumer"
  end

  test "generate_mermaid/1 renders subgraphs and edges" do
    mermaid = Contexts.generate_mermaid(TestContexts.__dialup_contexts__())

    assert mermaid =~ "subgraph Ordering"
    assert mermaid =~ "subgraph Payment"
    assert mermaid =~ "-- \"OrderConfirmed\" -->"
    assert mermaid =~ "-- \"PaymentCompleted\" -->"
  end

  test "find_context/2 resolves aggregate ownership" do
    contexts = TestContexts.__dialup_contexts__()

    assert Contexts.find_context(Dialup.ContextsTest.Ordering.Commands.AddItem, contexts) ==
             :ordering

    assert Contexts.find_context(Dialup.ContextsTest.Payment.Aggregates.Transaction, contexts) ==
             :payment
  end
end
