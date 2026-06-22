defmodule Dialup.App.Page do
  use Dialup.Page

  def agent_grant(_assigns) do
    %{
      capabilities: [:add_item, :submit, :focus, :read_audit_log],
      projections: [:state, :regions, :actions],
      approval: :per_action,
      expires_in: :timer.minutes(15),
      require_version: true
    }
  end

  def mount(_params, assigns) do
    {:ok, Map.merge(assigns, %{items: [], status: :draft, last_actor: "none"})}
  end

  def __available__(:add_item, assigns), do: assigns.status == :draft
  def __available__(:submit, assigns), do: assigns.status == :draft and assigns.items != []

  def agent_state(assigns) do
    %{items: assigns.items, status: assigns.status, last_actor: assigns.last_actor}
  end

  def agent_message(_assigns) do
    %{
      concept:
        "A human and an AI co-edit one invoice held by a single server-side session process.",
      goal:
        "Complete the handoff demo by reading the invoice, visibly focusing item_list, " <>
          "and adding exactly one AI line item with add_item. " <>
          "Submitting is a separate optional demonstration and always requires human approval.",
      expected_result:
        "The invoice contains exactly one newly added AI-DISCOVERED line; any pre-existing " <>
          "human lines remain unchanged. last_actor is AI, status remains draft, and the " <>
          "state version increments by one.",
      recommended_flow: [
        "Call read_scene and retain its version.",
        "Call focus with target=item_list.",
        "Call add_item exactly once with sku=AI-DISCOVERED, qty=1, and _version.",
        "Verify the returned scene contains AI-DISCOVERED and last_actor=AI.",
        "Do not call submit unless explicitly testing approval."
      ],
      human_first:
        "Optional. A human item is illustrative and is not a prerequisite. The AI should " <>
          "continue whether the invoice is empty or already contains human lines.",
      approval_model:
        "The grant policy is per-action. Only actions whose confirm metadata is human open " <>
          "an approval dialog; add_item does not require approval.",
      lifecycle:
        "An ordinary URL is not access to a user's existing browser session. For an existing-work " <>
          "handoff, ask the user to click Hand off to AI and send the generated /agent/ URL. " <>
          "On expiry, ask the user to issue a fresh URL from the still-open page.",
      safety: [
        "Never retry a stale action without reading the new scene.",
        "Do not bypass confirm=human actions.",
        "add_item only changes this local in-memory demo invoice; it does not charge, send, " <>
          "persist externally, or contact another system."
      ]
    }
  end

  def handle_event(:add_item, params, assigns) do
    sku = params["sku"] || params[:sku] || "UNKNOWN"
    qty = params["qty"] || params[:qty] || 1
    qty = if is_binary(qty), do: String.to_integer(qty), else: qty
    actor = if String.starts_with?(sku, "AI-"), do: "AI", else: "human"

    item = %{sku: sku, qty: qty, actor: actor}
    {:update, overwrite(assigns, %{items: assigns.items ++ [item], last_actor: actor})}
  end

  def handle_event(:submit, _params, assigns) do
    {:update, overwrite(assigns, %{status: :submitted, last_actor: "human"})}
  end

  def render(assigns) do
    ~H"""
    <main>
      <header>
        <p class="eyebrow">ONE PROCESS · TWO OPERATORS</p>
        <h1>Human → AI handoff</h1>
        <p>Both sides operate the same server-side invoice session.</p>
      </header>

      <section class="steps">
        <div>
          <strong>1 · Human (optional)</strong>
          <p>Add a human item first, or let the AI start from an empty invoice.</p>
          <.dialup_action
            name={:add_item}
            desc="Add a line item to the shared invoice"
            params={%{sku: :string, qty: {:integer, default: 1}}}
            risk="low"
            effects="Appends one line to this local in-memory demo invoice only."
            reversible={false}
            idempotent={false}
            examples={[%{sku: "AI-DISCOVERED", qty: 1}]}
            success="The new SKU appears in item_list, last_actor becomes AI, and version increments."
            available={@status == :draft}
            sku="HUMAN-ITEM"
            qty="1"
          >
            Add HUMAN-ITEM
          </.dialup_action>
        </div>
        <div>
          <strong>2 · Handoff</strong>
          <p>Click “AIに引き継ぐ” at the bottom-right and copy the generated URL.</p>
        </div>
        <div>
          <strong>3 · AI</strong>
          <p>Send the generated <code>/agent/…</code> URL to the AI.</p>
        </div>
      </section>

      <.dialup_region
        name={:item_list}
        role="list"
        desc="Current invoice line items"
        data={:items}
        actions={[:add_item, :submit]}
        class="invoice"
      >
        <div class="invoice-head">
          <h2>Invoice items</h2>
          <span class={"status status-#{@status}"}>{@status}</span>
        </div>

        <p :if={@items == []} class="empty">No items yet.</p>
        <ol>
          <li :for={item <- @items}>
            <span>{item.sku} × {item.qty}</span>
            <small>added by {item.actor}</small>
          </li>
        </ol>

        <p class="last-actor">Last action: <strong>{@last_actor}</strong></p>
      </.dialup_region>

      <.dialup_action
        name={:submit}
        desc="Submit the invoice"
        params={%{}}
        risk="high"
        effects="Changes this demo invoice from draft to submitted and disables further edits."
        reversible={false}
        idempotent={false}
        examples={[%{}]}
        success="status becomes submitted and both actions become unavailable."
        available={@status == :draft and @items != []}
        confirm={:human}
        class="submit"
      >
        Submit (human-confirmed)
      </.dialup_action>
    </main>
    """
  end
end
