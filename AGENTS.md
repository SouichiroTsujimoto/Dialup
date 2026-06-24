# Coding-agent guidance for Dialup

When implementing a Dialup application, read these in order:

1. `guides/agent-native-app-development.md`
2. `guides/mcp-api.md`
3. `guides/agent-handoff.md` (session tokens)

Treat the page's server-side session as the single source of truth. Do not create a
separate agent API or duplicate business logic. UI declarations become HTTP MCP tools.

For agent-enabled pages:

- declare state-changing operations with `<.dialup_action>` / `declare_action/1`;
- implement them once in `handle_event/3`;
- add `__available__/2` predicates for live server-side availability;
- use `<.dialup_region>` for stable domain areas and structured data;
- expose an allowlisted projection through `agent_state/1`;
- explain goals and safety through `agent_message/1`;
- grant the minimum capabilities and projections through `agent_grant/1`;
- use `confirm: :human` for irreversible operations (not callable over HTTP MCP);
- test stale versions, grant expiry, and HTTP `tools/list` / `tools/call`.

Agents connect via `POST /agent/:token` (JSON-RPC). There is no agent WebSocket transport.
Obtain a session token programmatically or through `POST /_dialup/agent-handoff`.
