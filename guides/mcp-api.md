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

### The declaration boundary

`<.dialup_action>` / `declare_action` is the **single boundary** of what an agent can do. Dialup
never auto-exposes raw `ws-event`, `ws-submit`, `ws-change`, or `ws-href` elements as tools. This is
deliberate: an agent is an untrusted external caller, so each tool needs a validated input schema, a
description, availability and confirmation rules — none of which can be inferred from an arbitrary
`handle_event/3` clause. It also keeps internal plumbing events out of the agent's surface.

The principle is *parity by declaration*, not parity by default: when you write a control with
`<.dialup_action>` it is human- and agent-operable at once, and that includes **navigation** — see
[Navigating between pages](#navigating-between-pages). If you want the agent to do something, declare
it; if a human-facing control should be agent-operable, express it with `<.dialup_action>`.

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
| `tools/call` | Invoke `read_scene`, `read_audit_log`, `lock_ui`, `unlock_ui`, or a declared action (including navigation actions) |

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

## Navigating between pages

Navigation is **not** a free-form tool. It follows the same principle as every other capability:
an agent can reach exactly the links your UI declares — no more, no less. Declare a navigable link
with `navigate` on `<.dialup_action>`:

```elixir
<.dialup_action navigate="/docs/concepts">Concepts</.dialup_action>
```

This renders an ordinary `ws-href` link for humans and, from the same declaration, generates a
navigation tool for agents. The tool name is derived from the path (`/docs/concepts` →
`navigate_docs_concepts`); pass an explicit `name={...}` to override it. The action takes no
arguments because the destination is fixed at the declaration site:

```json
{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"navigate_docs_concepts","arguments":{}}}
```

Calling it runs the same code path as a human clicking the link: the page re-mounts and the human's
browser follows in real time. Each page generates a different tool catalog, so call `tools/list`
(or `read_scene`) again afterwards. The destination of each navigation action is reported in
`tools/list` under `_meta.navigate` and in `read_scene` actions under `navigate`.

Navigation links declared on a **layout** (for shared chrome like a nav bar) are merged into the
tool catalog of every page under that layout, so an agent gets the same site-wide navigation a human
sees. Because navigation actions are ordinary actions, they are gated by capability under their
derived name (e.g. `:navigate_docs_concepts`); a `:all` grant includes them automatically.

## Locking the human UI

While an agent works, it can stop the human from operating the page to avoid conflicting edits.
Two built-in tools control this (gated by the `:lock_ui` capability):

```json
{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"lock_ui","arguments":{"reason":"AIが整理中です"}}}
```

```json
{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"unlock_ui","arguments":{}}}
```

While locked:

- The browser shows a blocking overlay with the optional `reason`.
- Human `ws-event`/`ws-submit`/`ws-change` interactions are ignored server-side (defense in depth).
- Agent tool calls still apply normally, and `read_scene` reports `"uiLocked": true`.

Grant the capability explicitly so agents can use it:

```elixir
def agent_grant(_assigns) do
  %{capabilities: [:add_item, :lock_ui], projections: [:state, :regions, :actions]}
end
```

Always pair `lock_ui` with `unlock_ui` (e.g. in a `try/after`) so the human regains control even if
the agent errors out. A session timeout also releases the lock when the process is rebuilt.

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
- **No focus tool** — semantic regions and `read_scene` carry the structured context. To prevent
  concurrent human edits, use `lock_ui` / `unlock_ui` (above) instead.

Agents *can* navigate (via declared navigation actions) and lock the UI (`lock_ui`), mirroring human
capabilities. What an agent cannot do is anything you leave undeclared and ungranted: raw `ws-event`
/ `ws-submit` / `ws-href` elements are **never** auto-exposed. A page event or a link becomes a tool
only through `<.dialup_action>` / `declare_action`, and built-ins like `lock_ui` require their
capability. The single declaration boundary keeps the agent's surface typed, documented, and
intentional rather than a mirror of every internal event.

## Demos and references

- [Building agent-native applications](./agent-native-app-development.md) — implementation workflow
- [Live demo](https://dialup-framework.org/agent_demo) — interactive playground on dialup-framework.org
