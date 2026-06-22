# Building agent-native Dialup applications

This guide is written for coding agents and developers implementing applications on
Dialup's shared human/AI session model.

The central rule is:

> Build one server-side actor, then derive a human HTML projection and a constrained
> machine-readable projection from the same state and event handlers.

Do not build a separate automation API that duplicates page logic. Declare semantic
actions and regions in the page that owns the state.

## The application contract

An agent-enabled page has five parts:

1. `mount/2` creates the session state.
2. `handle_event/3` is the single implementation of state-changing operations.
3. `<.dialup_action>` declares operations available to humans and agents.
4. `<.dialup_region>` declares stable semantic areas and their projected data.
5. `agent_state/1`, `agent_message/1`, and `agent_grant/1` define the machine projection,
   operating instructions, and authority boundary.

Human browser events and agent tool calls are serialized through the same
`UserSessionProcess`. Every mutation advances a state version. Agents must read the scene,
pass `_version`, and recover from stale state instead of retrying blindly.

## Implementation workflow for a coding agent

When asked to build an agent-native Dialup page, follow this order.

### 1. Model the shared state

Keep state needed by both operators in page assigns or layout session state. Do not create
a second agent-only state store.

```elixir
def mount(_params, assigns) do
  {:ok, Map.merge(assigns, %{items: [], status: :draft})}
end
```

### 2. Identify state-changing actions

For every operation, define:

- a stable snake-case name;
- a concrete description;
- a complete input schema;
- observable effects;
- risk and reversibility;
- one or more valid examples;
- a success condition;
- whether human confirmation is required.

Put one-off action metadata directly on `<.dialup_action>`. For controls rendered in
multiple places, use `declare_action/1` once and render bare references. Use
`agent_only: true` only when an operation intentionally has no human control.

```elixir
<.dialup_action
  name={:add_item}
  desc="Append one line item to the draft invoice"
  params={%{sku: :string, qty: {:integer, default: 1}}}
  risk="low"
  effects="Changes only the current draft invoice."
  reversible={false}
  idempotent={false}
  examples={[%{sku: "SKU-1", qty: 1}]}
  success="The SKU appears in item_list and the version increments."
  available={@status == :draft}
  sku="SKU-1"
  qty="1"
>
  Add SKU-1
</.dialup_action>
```

The action implementation remains in `handle_event/3`:

```elixir
def handle_event(:add_item, params, assigns) do
  item = %{sku: params["sku"], qty: params["qty"]}
  {:update, overwrite(assigns, %{items: assigns.items ++ [item]})}
end
```

Agent arguments are validated before this handler runs. Handlers should still enforce
domain invariants and authorization because schema validation is not business validation.

### 3. Define live availability

The HTML `available={...}` value controls the rendered button. Define `__available__/2`
with the same predicate so agent calls are checked against current server state:

```elixir
def __available__(:add_item, assigns), do: assigns.status == :draft
def __available__(:submit, assigns), do: assigns.status == :draft and assigns.items != []
```

Never rely only on disabled HTML. Agent calls do not click the button.

### 4. Add regions where meaning must survive layout changes

Use a region for a domain object or workspace that an agent should refer to by a stable
name:

```elixir
<.dialup_region
  name={:item_list}
  role="list"
  desc="Line items in the current invoice"
  data={:items}
  actions={[:add_item, :submit]}
>
  ...
</.dialup_region>
```

`data` may be an assign key such as `:items` or a nested key path. `actions` expresses
which operations conceptually apply to the region. `parent` can express region nesting.

Do not wrap every decorative element in a region. Humans can point at ordinary visible DOM
elements with Dialup's spatial-selection UI. Ordinary DOM references contain generated
selectors and coordinates; they are useful for “this paragraph” or “the button over
there,” but may become stale after a re-render.

Choose a region when at least one of these is true:

- the target needs a stable name across layout and responsive changes;
- the agent needs structured data not fully present in the DOM;
- the target owns or relates to declared actions;
- content may be virtualized, collapsed, canvas-rendered, or off-screen;
- grants should expose the domain area without exposing unrelated page content;
- audit logs and focus should remain meaningful across versions.

### 5. Project only necessary state

`agent_state/1` is an allowlist, not a dump of assigns:

```elixir
def agent_state(assigns) do
  %{
    items: assigns.items,
    status: assigns.status
  }
end
```

Exclude secrets, CSRF material, credentials, internal records, and unrelated personal
data. Region `data` follows the same rule.

### 6. Explain the application to an unfamiliar agent

`agent_message/1` should make the page usable without repository context:

```elixir
def agent_message(_assigns) do
  %{
    concept: "A human and an AI edit one draft invoice in a shared live session.",
    goal: "Help the user review and update invoice line items.",
    recommended_flow: [
      "Read the scene and retain its version.",
      "Read humanFocus when the user referred to a place on screen.",
      "Focus the affected region before mutation.",
      "Perform one action with _version.",
      "Read the scene again and verify the documented success condition."
    ],
    safety: [
      "Never bypass confirm=human.",
      "On stale error -32009, read the scene and reconsider the action.",
      "Do not submit unless the user explicitly requested it."
    ]
  }
end
```

Include the business concept, expected goals, prerequisites, ambiguity handling, success
criteria, and prohibited actions. Avoid instructions that assume the agent has seen the
source code.

### 7. Grant least authority

```elixir
def agent_grant(_assigns) do
  %{
    capabilities: [:add_item, :submit, :focus, :read_audit_log],
    projections: [:state, :regions, :actions],
    approval: :per_action,
    expires_in: :timer.minutes(10),
    require_version: true
  }
end
```

Capability URLs are bearer credentials. Keep grants short-lived and narrow. Mark
irreversible or externally visible operations with `confirm={:human}`.

An ordinary page URL never grants access to the user's existing tab. The user must click
**AIに引き継ぐ / Hand off to AI** and share the generated `/agent/...` URL. If it expires,
the agent asks the user to issue another URL from the still-open page.

## Complete page skeleton

```elixir
defmodule Dialup.App.Invoices.Page do
  use Dialup.Page

  def mount(_params, assigns) do
    {:ok, Map.merge(assigns, %{items: [], status: :draft})}
  end

  def __available__(:add_item, assigns), do: assigns.status == :draft
  def __available__(:submit, assigns), do: assigns.status == :draft and assigns.items != []

  def agent_state(assigns), do: %{items: assigns.items, status: assigns.status}

  def agent_grant(_assigns) do
    %{
      capabilities: [:add_item, :submit, :focus],
      projections: [:state, :regions, :actions],
      approval: :per_action,
      expires_in: :timer.minutes(10),
      require_version: true
    }
  end

  def agent_message(_assigns) do
    %{
      concept: "One draft invoice shared by a human and an AI.",
      recommended_flow: [
        "Call read_scene.",
        "Use humanFocus if present.",
        "Focus item_list.",
        "Call one action with _version.",
        "Verify the result."
      ],
      safety: ["Submission requires the human's approval."]
    }
  end

  def handle_event(:add_item, params, assigns) do
    item = %{sku: params["sku"], qty: params["qty"]}
    {:update, overwrite(assigns, %{items: assigns.items ++ [item]})}
  end

  def handle_event(:submit, _params, assigns) do
    {:update, overwrite(assigns, %{status: :submitted})}
  end

  def render(assigns) do
    ~H"""
    <.dialup_region
      name={:item_list}
      role="list"
      desc="Current invoice line items"
      data={:items}
      actions={[:add_item, :submit]}
    >
      <ul><li :for={item <- @items}>{item.sku} × {item.qty}</li></ul>
    </.dialup_region>

    <.dialup_action
      name={:add_item}
      desc="Append one line item"
      params={%{sku: :string, qty: {:integer, default: 1}}}
      risk="low"
      effects="Changes the current draft only."
      reversible={false}
      idempotent={false}
      examples={[%{sku: "SKU-1", qty: 1}]}
      success="The item appears in item_list."
      available={@status == :draft}
      sku="SKU-1"
      qty="1"
    >
      Add item
    </.dialup_action>

    <.dialup_action
      name={:submit}
      desc="Submit the invoice"
      params={%{}}
      risk="high"
      effects="Makes the invoice final."
      reversible={false}
      idempotent={false}
      success="status becomes submitted."
      available={@status == :draft and @items != []}
      confirm={:human}
    >
      Submit
    </.dialup_action>
    """
  end
end
```

## Runtime behavior an agent must understand

- `read_scene` returns `state`, `regions`, `actions`, `version`, and the latest
  `humanFocus`.
- `focus` highlights a semantic action or region in purple until another focus or manual
  dismissal.
- Human spatial selection prefers regions/actions and falls back to ordinary DOM targets.
- Mutations require `_version` unless the grant explicitly disables that requirement.
- Stale mutations fail with JSON-RPC error `-32009`.
- `confirm: :human` creates a pending approval instead of executing immediately.
- Agent WebSockets receive `state_changed`, `focus`, `approval_resolved`, and
  `grant_revoked`.
- `read_audit_log` exposes the ordered human/agent activity log only when granted.

## Verification checklist

Before considering an agent-native page complete:

- [ ] Every exposed mutation has exactly one `handle_event/3` implementation.
- [ ] Every action has `desc`, `params`, effects, risk, and a verifiable success condition.
- [ ] Browser and agent availability use the same predicate.
- [ ] High-risk or externally visible operations require human confirmation.
- [ ] `agent_state/1` and region data contain no secrets or unnecessary personal data.
- [ ] Important domain areas have stable region names.
- [ ] `agent_message/1` is understandable without source-code context.
- [ ] A normal URL explains how to request a handoff URL.
- [ ] A generated handoff URL can read the exact state already open in the human tab.
- [ ] Human clicks and rectangle selections appear in `read_scene.humanFocus`.
- [ ] Agent focus remains visibly highlighted in the browser.
- [ ] Stale-version, approval, grant expiry, and revocation paths are tested.

Use `examples/handoff_demo` as an executable reference.
