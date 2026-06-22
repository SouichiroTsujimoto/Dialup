# Human → AI session handoff

Dialup exposes a live browser session as a scoped capability URL. Human events and agent
calls are serialized by the same session process, so both operators observe one ordered
state history.

For a step-by-step application implementation workflow, read
[Building agent-native Dialup applications](./agent-native-app-development.md) first.

## Declare actions, regions, and the agent projection

```elixir
defmodule Dialup.App.Page do
  use Dialup.Page

  def agent_state(assigns), do: %{status: assigns.status, items: assigns.items}

  def agent_message(_assigns) do
    %{
      concept: "A human and an AI co-edit one invoice in a shared session.",
      goal: "Review the invoice and add valid line items.",
      recommended_flow: [
        "Read the scene and retain its version.",
        "Focus item_list before changing it.",
        "Pass _version to every mutating action."
      ],
      safety: ["Submit requires human approval."]
    }
  end

  def agent_grant(_assigns) do
    %{
      capabilities: [:add_item, :submit, :focus, :read_audit_log],
      projections: [:state, :regions, :actions],
      approval: :per_action,
      expires_in: :timer.minutes(5),
      require_version: true
    }
  end

  def render(assigns) do
    ~H"""
    <.dialup_region
      name={:item_list}
      role="list"
      desc="Invoice line items"
      data={:items}
      actions={[:add_item, :submit]}
    >
      <ul><li :for={item <- @items}>{item.sku} × {item.qty}</li></ul>
    </.dialup_region>

    <.dialup_action
      name={:add_item}
      desc="Add a line item"
      params={%{sku: :string, qty: {:integer, default: 1}}}
      risk="low"
      effects="Appends one local demo line item."
      reversible={false}
      idempotent={false}
      examples={[%{sku: "AI-DISCOVERED", qty: 1}]}
      success="The SKU appears, last_actor is AI, and version increments."
      sku="HUMAN-ITEM"
      qty="1"
    >
      Add item
    </.dialup_action>

    <.dialup_action
      name={:submit}
      desc="Submit the invoice"
      params={%{}}
      confirm={:human}
    >
      Submit
    </.dialup_action>
    """
  end
end
```

Inline action metadata is extracted into the catalog at compile time. For repeated controls,
hoist metadata with `declare_action` and use bare `<.dialup_action name={...}>` references.
Duplicate or incomplete metadata fails compilation. Mark a module declaration
`agent_only: true` when it intentionally has no human control.

## Discovery from an ordinary URL

The ordinary URL is for understanding the application, not for accessing a user's existing
browser session. Every agent-enabled page:

- returns a `Link` response header pointing to
  `/.well-known/dialup-agent?path=/current/path`;
- includes a `<link rel="alternate">` discovery entry;
- includes a non-rendered
  `<script id="dialup-agent-context" type="application/json">` element.

The discovery document contains `agent_message/1`, the static action catalog, input
schemas, semantic regions, and connection instructions. It deliberately contains no live
bearer token during the initial HTTP response.

For broad agent compatibility the page also advertises `rel=service-desc`, a `/llms.txt`
guide, a session-isolation warning, a suggested response to the user, explicit JSON-RPC
examples, stale-version recovery, endpoint-expiry recovery, and action-level `risk`,
`effects`, `reversible`, `idempotent`, `examples`, and `success` metadata.

Opening the ordinary URL in an agent-controlled browser creates or selects that browser
tab's own session. It cannot attach to work already open in the user's browser. Therefore,
when the user asks the agent to continue or partly operate existing work but supplies only
the ordinary URL, the agent must ask for a handoff URL.

Dialup adds an **AIに引き継ぐ / Hand off to AI** control to every connected page. The
user clicks it and sends the generated `/agent/...` URL to the agent. That URL is a
short-lived bearer capability for the exact session open in the user's tab. If it expires,
the agent asks the user to issue a fresh URL from the still-open page.

The hidden `#dialup-agent-context` remains useful to browser agents that intentionally
start a separate new session, but labels that endpoint as belonging only to the newly
opened browser tab.

## Human spatial references

Dialup adds an **AIに場所を伝える** control next to the handoff control. The user can
click any meaningful visible element or drag a rectangle to identify intersecting
elements.

Semantic actions and regions are preferred because they have stable IDs and declared
meaning. Ordinary headings, paragraphs, links, form controls, images, and similar DOM
elements are also selectable and are sent with a generated selector. The browser sends
descriptions, visible text excerpts, viewport coordinates, document coordinates, and the
selection rectangle. It does not send form-control values.

Connected Agent WebSockets receive a `focus` notification. The latest selection is also
retained in the session and returned as `read_scene.humanFocus`, so a user may select the
location before sharing the handoff URL.

When an agent calls `focus`, the browser keeps the purple outline visible across state
updates until another target is focused or the human clicks **解除**.

## Capability grants

The ordinary page and its hidden agent context do not expose an agent endpoint. The
standard handoff control mints a fresh delegated token using `agent_grant/1`. Tokens are
unguessable bearer capabilities and are invalidated when the session process ends.

An application can mint a narrower delegated grant:

```elixir
{:ok, grant} =
  Dialup.Session.grant(session_pid,
    capabilities: [:add_item],
    projections: [:state],
    expires_in: :timer.minutes(2),
    require_version: true
  )
```

Use `Dialup.Session.revoke/2` or `DELETE /agent/:token` to revoke it. Connected agent
WebSockets receive a `grant_revoked` notification.

## MCP-compatible JSON-RPC

The HTTP endpoint supports the MCP lifecycle and tool subset:

- `initialize`
- `notifications/initialized`
- `ping`
- `tools/list`
- `tools/call`

The supported stable protocol version is `2025-11-25`.

Read the semantic scene:

```json
{"jsonrpc":"2.0","id":1,"method":"tools/call",
 "params":{"name":"read_scene","arguments":{}}}
```

Mutating actions require the version returned by `read_scene`:

```json
{"jsonrpc":"2.0","id":2,"method":"tools/call",
 "params":{"name":"add_item",
           "arguments":{"sku":"AI-ITEM","qty":2,"_version":4}}}
```

If another operator changes state first, the call fails with error `-32009` and the
current version. Arguments are checked against the generated schema and defaults are
applied before `handle_event/3` runs.

## Focus and human approval

`focus` is non-mutating and highlights the semantic target in the browser:

```json
{"jsonrpc":"2.0","id":3,"method":"tools/call",
 "params":{"name":"focus","arguments":{"target":"item_list"}}}
```

For `confirm: :human`, Dialup displays a browser approval dialog and returns an
`approval_id`. Approval executes the pending action only if its state version and
availability are still valid. The agent can call `approval_status` to read the result.

Human clicks on semantic regions are translated to semantic focus events. Client code can
also call `Dialup.focus("item_list")` or `Dialup.focusAt(x, y)`.

## Full-duplex agent connection

Connect a WebSocket to `/agent/:token/ws`. It accepts the same JSON-RPC requests and sends
notifications:

- `state_changed`
- `focus`
- `approval_resolved`
- `grant_revoked`

The HTTP endpoint remains useful for ordinary MCP request/response clients.

## Audit and distribution

`read_audit_log` returns the bounded ordered log of human and agent actions. Grant access
to it explicitly unless the grant uses `capabilities: :all`.

Agent tokens are registered locally and through Erlang `:global`, allowing requests on a
connected BEAM node to resolve the owning session process. Production HTTP routing still
needs the BEAM nodes connected and normal cluster/network configuration.

## Complete demo

See [`examples/handoff_demo`](../examples/handoff_demo/README.md).
