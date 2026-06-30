# Building agent-native Dialup applications

This guide is written for coding agents and developers implementing applications on Dialup.

The central rule is:

> Build one server-side actor, then derive a human HTML projection and an HTTP MCP tool
> catalog from the same state and event handlers.

Do not build a separate automation API that duplicates page logic. Declare semantic actions and
regions in the page that owns the state.

## The application contract

An agent-enabled page has five parts:

1. `mount/2` creates the session state (often from a Commanded read model).
2. `<.dialup_action>` / `declare_action/1` declare operations in one of four modes:
   `command`, `set`, `navigate`, or legacy `name`/`handle_event/3`.
3. `<.dialup_region>` / `declare_region/1` declare stable semantic areas and projected data.
4. `agent_state/1`, `agent_message/1`, and `agent_grant/1` define the machine projection,
   operating instructions, and authority boundary.
5. Optional: `handle_event/3` for legacy actions not yet migrated to declarative modes.

For Commanded-backed pages, prefer `command` and `set` modes so the framework dispatches
commands and updates assigns without duplicating logic in `handle_event/3`.

Human browser events and agent `tools/call` requests are serialized through the same
`UserSessionProcess`. Every mutation advances a state version. Agents must read the scene,
pass `_version`, and recover from stale state instead of retrying blindly.

For the HTTP API surface, read [HTTP MCP API](./mcp-api.md).

## Implementation workflow

When asked to build an agent-native Dialup page, follow this order.

### 1. Model the shared state

Keep state needed by both operators in page assigns or layout session state. Do not create a
second agent-only state store.

### 2. Identify state-changing actions

For every operation, define a stable name, description, input schema, effects, risk,
reversibility, examples, success criteria, and whether human confirmation is required.

Put metadata on `<.dialup_action>` or hoist with `declare_action/1`.

**Action modes:**

| Mode | Attribute | Routing |
|------|-----------|---------|
| `command` | `command={{Context, :cmd}}` | Builds a Commanded command, calls `Context.dispatch/1`, remounts the page |
| `set` | `set={%{key: value}}` | Merges the rendered update map into assigns |
| `navigate` | `navigate="/path"` | Navigates to another page |
| `action` (legacy) | `name={:event}` | Calls `handle_event/3` |

Example command action:

```elixir
<.dialup_action
  command={{MyApp.Ordering, :add_item}}
  desc="Add a line item"
  params={%{sku: :string, qty: :integer}}
  bind={%{order_id: @order.id}}
  errors={%{too_many_items: "Cannot add more items"}}
  available={@order.status == :draft}
>
  Add item
</.dialup_action>
```

Example set action (UI-only state):

```elixir
<.dialup_action
  name={:toggle_sidebar}
  desc="Toggle the sidebar"
  set={%{sidebar_open: !@sidebar_open}}
>
  Toggle
</.dialup_action>
```

Generate Commanded scaffolding with:

```bash
mix dialup.gen.aggregate Ordering Order orders add_item:sku:string confirm
```

Map bounded contexts with `use Dialup.Contexts` and inspect the graph via
`mix dialup.context_map` (see `Dialup.Contexts` moduledoc).

### 3. Define live availability

Write the same predicate on the HTML control and in action metadata. Dialup derives
`__available__/2` from `available={...}` at compile time — you do not need to implement it by
hand unless you are mixing manual and declarative actions.

```elixir
<.dialup_action
  command={{MyApp.Ordering, :confirm}}
  available={@order.status == :draft and @order.lines != []}
  ...
/>
```

Agent calls are checked server-side against the generated `__available__/2`; they do not click
buttons. Defining `__available__/2` manually while also using `available={...}` on the same page
is a compile error.

#### Migrating from hand-written `__available__/2`

1. Copy each predicate from your existing `def __available__(action, assigns)` clauses.
2. Paste it into `available={...}` on the matching `<.dialup_action>` (use `@assign` syntax in
   HEEx) or into `declare_action available: quote(do: assigns.field == ...)` for hoisted actions.
3. Delete the manual `__available__/2` definitions.
4. Run `mix test`. If both manual and derived availability remain, compilation fails with a
   clear error pointing at the conflict.

The HTML `available={...}` attribute and the generated server predicate always stay in sync —
agents see the same gates as humans in the browser.

### 4. Add regions where meaning must survive layout changes

Use regions for domain objects an agent should refer to by stable name. Include `data` when the
agent needs structured state not fully present in the DOM.

### 5. Project only necessary state

`agent_state/1` is an allowlist, not a dump of assigns. Exclude secrets and unrelated personal
data.

### 6. Explain the application to an unfamiliar agent

`agent_message/1` should describe the business concept, goals, recommended flow, and safety
constraints without assuming repository access.

### 7. Grant least authority

```elixir
def agent_grant(_assigns) do
  %{
    capabilities: [:add_item, :read_audit_log],
    projections: [:state, :regions, :actions],
    expires_in: :timer.minutes(10),
    require_version: true
  }
end
```

Capability URLs are bearer credentials. Mark irreversible operations with `confirm={:human}` —
they return an isError tool result over HTTP MCP and must be performed in the human UI.

## Runtime behavior an agent must understand

- `read_scene` returns `state`, `regions`, `actions`, and `version` (subject to grant projections).
- Mutations require `_version` unless the grant sets `require_version: false`.
- Stale mutations return an isError tool result whose `structuredContent.currentVersion` is the latest.
- `confirm: :human` is not executable via HTTP MCP (it returns an isError tool result).
- `read_audit_log` exposes the ordered human/agent activity log when granted.
- Agents use HTTP only — there is no agent WebSocket transport.

## Agent-first sessions and browser handoff

When no human tab exists yet, start a headless session with `Dialup.Session.start/2` or
`POST /_dialup/agent-session`, operate over MCP, then invite a human with `issue_browser_url`.
The human opens the one-time `browserUrl`; finalize-join sets their cookie and attaches them to
the same `UserSessionProcess`. Read [Session tokens for HTTP MCP](./agent-handoff.md) for the full
attach → finalize → reconnect sequence.

## Verification checklist

- [ ] Every exposed mutation is declared with `<.dialup_action>` / `declare_action/1`.
- [ ] Command-backed mutations use `command={...}` and a `Dialup.CommandedContext` module.
- [ ] Every action has `desc`, `params`, effects, risk, and a verifiable success condition.
- [ ] Browser and agent availability use the same `available={...}` predicate.
- [ ] `agent_state/1` and region data contain no secrets.
- [ ] `agent_message/1` is understandable without source-code context.
- [ ] `tools/list` matches the declared actions on the page (check `_meta.mode`).
- [ ] Stale-version, grant expiry, and revocation paths are tested.

Use [dialup-framework.org/agent_demo](https://dialup-framework.org/agent_demo) as a reference.
