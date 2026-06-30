defmodule Dialup.ContextsTest.Contexts do
  @moduledoc false
  use Dialup.Contexts

  context :ordering do
    commanded_context Dialup.ContextsTest.Ordering
    aggregates [Dialup.ContextsTest.Ordering.Aggregates.Order]
    events_out [:OrderConfirmed]
    events_in [:PaymentCompleted]
  end

  context :payment do
    commanded_context Dialup.ContextsTest.Payment
    aggregates [Dialup.ContextsTest.Payment.Aggregates.Transaction]
    events_out [:PaymentCompleted]
    events_in [:OrderConfirmed]
  end
end
