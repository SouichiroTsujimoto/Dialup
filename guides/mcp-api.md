# HTTP MCP API

Dialup has two equal surfaces: a WebSocket-first browser UI for humans and an auto-generated
HTTP MCP API for agents. This guide covers the agent API side. Dialup derives an MCP-compatible
HTTP JSON-RPC API from the same UI declarations that power the browser interface, so you declare
actions and regions once; agents receive `tools/list`, `tools/call`, and `read_scene` without a
second API layer.

## The core idea

```
<.dialup_action>  ─┐
declare_action/1   ─┼─→  tools/list  ──→  POST /agent/{token}
<.dialup_region>   ─┘         │
declare_region/1              tools/call ──→ handle_event/3 (same session process)
```

Human operators use WebSocket (`/ws`). AI agents use HTTP request-response (`POST /agent/:token`).
Both paths serialize through the same `UserSessionProcess`, so state, versions, and audit logs stay
consistent.

## Minimal page

```elixir
defmodule Dialup.App.Invoice.Page do
  use Dialup.Page

  declare_action name: :add_item,
                 desc: "Add a line item",
                 params: %{sku: :string, qty: {:integer, default: 1}}

  declare_region name: :items, role: "list", desc: "Invoice line items", data: :items

  def mount(_params, assigns), do: {:ok, Map.put(assigns, :items, [])}

  def __available__(:add_item, _assigns), do: true

  def agent_state(assigns), do: %{items: assigns.items}

  def handle_event(:add_item, params, assigns) do
    item = %{sku: params["sku"], qty: params["qty"]}
    {:update, Map.put(assigns, :items, assigns.items ++ [item])}
  end

  def render(assigns) do
    ~H"""
    <.dialup_region name={:items} role="list" desc="Invoice line items">
      <ul><li :for={i <- @items}>{i.sku} × {i.qty}</li></ul>
    </.dialup_region>

    <.dialup_action name={:add_item} sku="SKU-1" qty="1">Add item</.dialup_action>
    """
  end
end
```

No separate REST controller. No OpenAPI hand-authoring. The catalog is derived from compile-time
declarations and runtime availability via `__available__/2`.

## Discovery

Every agent-enabled page advertises:

- HTTP `Link` header → `/.well-known/dialup-agent?path=/current/path`
- Embedded `<script id="dialup-agent-context" type="application/json">`
- `/llms.txt` — operator instructions for coding agents

The discovery document includes `agent_message/1`, static tool schemas, semantic regions, and
HTTP connection instructions. It does **not** include a live session token.

## Session tokens

To operate a user's **live** browser session, obtain a bearer token:

1. **Programmatic** — `Dialup.Session.grant(session_pid, opts)`
2. **From the open tab** — `POST /_dialup/agent-handoff?tab_id=...` (uses the tab's registry key)

Then call:

```
POST /agent/{token}
Content-Type: application/json
```

## MCP lifecycle

Supported JSON-RPC methods:

| Method | Purpose |
|--------|---------|
| `initialize` | Protocol handshake (`2025-11-25`) |
| `notifications/initialized` | Client ready (no response body) |
| `ping` | Health check |
| `tools/list` | Generated tool catalog |
| `tools/call` | Invoke `read_scene`, `read_audit_log`, or a declared action |

### Typical flow

```json
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"agent","version":"1"}}}
```

```json
{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}
```

```json
{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"read_scene","arguments":{}}}
```

```json
{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"add_item","arguments":{"sku":"AI-1","qty":2,"_version":3}}}
```

Every mutating action should include the latest `_version` from `read_scene`. Stale calls return
error `-32009` with `currentVersion` — call `read_scene` again instead of blind retries.

## Human-only actions

Actions marked `confirm: :human` are **not** executable over HTTP MCP. They return error `-32004`.
Use the human browser UI for those operations.

## Scoped grants

```elixir
{:ok, grant} =
  Dialup.Session.grant(session_pid,
    capabilities: [:add_item],
    projections: [:state],
    expires_in: :timer.minutes(5),
    require_version: true
  )
```

`capabilities` limits which tools appear in `tools/list`. `projections` limits what `read_scene`
returns (`:state`, `:regions`, `:actions`). Revoke with `Dialup.Session.revoke/2` or
`DELETE /agent/:token`.

## Action metadata

Tool entries include `_meta` for agent decision-making:

- `available` — live predicate from `__available__/2`
- `confirm`, `risk`, `effects`, `reversible`, `idempotent`
- `examples`, `success`

Put metadata on `<.dialup_action>` for one-off controls, or hoist with `declare_action/1` for
repeated references. Use `agent_only: true` when an operation has no human button.

## What agents do not get

- **No agent WebSocket** — `/agent/:token/ws` is not supported. Use HTTP only.
- **No push notifications** — poll with `read_scene` or rely on request-response results.
- **No focus tool** — semantic regions and `read_scene` carry the structured context.

## Demos and references

- [Building agent-native applications](./agent-native-app-development.md) — implementation workflow
- [`examples/handoff_demo`](../examples/handoff_demo/README.md) — runnable HTTP MCP client
- [Live demo](https://dialup-framework.org/agent_demo) — interactive playground on dialup-framework.org
