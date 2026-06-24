# Building agent-native Dialup applications

This guide is written for coding agents and developers implementing applications on Dialup.

The central rule is:

> Build one server-side actor, then derive a human HTML projection and an HTTP MCP tool
> catalog from the same state and event handlers.

Do not build a separate automation API that duplicates page logic. Declare semantic actions and
regions in the page that owns the state.

## The application contract

An agent-enabled page has five parts:

1. `mount/2` creates the session state.
2. `handle_event/3` is the single implementation of state-changing operations.
3. `<.dialup_action>` / `declare_action/1` declare operations for humans and agents.
4. `<.dialup_region>` / `declare_region/1` declare stable semantic areas and projected data.
5. `agent_state/1`, `agent_message/1`, and `agent_grant/1` define the machine projection,
   operating instructions, and authority boundary.

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

Put metadata on `<.dialup_action>` or hoist with `declare_action/1`. The implementation lives
only in `handle_event/3`.

### 3. Define live availability

Define `__available__/2` with the same predicate as the HTML `available={...}` attribute.
Agent calls are checked server-side; they do not click buttons.

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
they return error `-32004` over HTTP MCP and must be performed in the human UI.

## Runtime behavior an agent must understand

- `read_scene` returns `state`, `regions`, `actions`, and `version` (subject to grant projections).
- Mutations require `_version` unless the grant sets `require_version: false`.
- Stale mutations fail with JSON-RPC error `-32009`.
- `confirm: :human` is not executable via HTTP MCP.
- `read_audit_log` exposes the ordered human/agent activity log when granted.
- Agents use HTTP only — there is no agent WebSocket transport.

## Verification checklist

- [ ] Every exposed mutation has exactly one `handle_event/3` implementation.
- [ ] Every action has `desc`, `params`, effects, risk, and a verifiable success condition.
- [ ] Browser and agent availability use the same `__available__/2` predicate.
- [ ] `agent_state/1` and region data contain no secrets.
- [ ] `agent_message/1` is understandable without source-code context.
- [ ] `tools/list` matches the declared actions on the page.
- [ ] Stale-version, grant expiry, and revocation paths are tested.

Use [`examples/handoff_demo`](../examples/handoff_demo/README.md) and
[dialup-framework.org/agent_demo](https://dialup-framework.org/agent_demo) as references.
