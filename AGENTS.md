# Coding-agent guidance for Dialup

When implementing a Dialup application, read these in order:

1. `guides/agent-native-app-development.md`
2. `guides/mcp-api.md`
3. `guides/agent-handoff.md` (session tokens)
4. `guides/agent-pitfalls.md` (common agent misunderstandings — check before adding page-specific CSS or ws-change handlers)

Treat the page's server-side session as the single source of truth. Do not create a
separate agent API or duplicate business logic. UI declarations become HTTP MCP tools.

For agent-enabled pages:

- declare state-changing operations with `<.dialup_action>` / `declare_action/1`;
- prefer `command={...}` (Commanded dispatch + remount) or inline `set={...}` for UI-only state;
  use `handle_event/3` only for legacy `name={:event}` actions or non-declarative controls;
- expose navigation with `<.dialup_action navigate="/path">` (on a page or a layout) so the agent
  reaches exactly the links the UI declares — raw `ws-href`/`ws-event` are never auto-exposed;
- derive availability with `available={...}` on actions (or `declare_action available: quote(...)`);
  avoid hand-written `__available__/2` when using declarative availability;
- use `<.dialup_region>` for stable domain areas and structured data;
- expose an allowlisted projection through `agent_state/1`;
- explain goals and safety through `agent_message/1`;
- grant the minimum capabilities and projections through `agent_grant/1`;
- use `confirm: :human` for irreversible operations (not callable over HTTP MCP);
- test stale versions, grant expiry, and HTTP `tools/list` / `tools/call`.

Agents connect via `POST /agent/:token` (JSON-RPC). There is no agent WebSocket transport.
Obtain a session token programmatically or through `POST /_dialup/agent-handoff`.

## Framework release (maintainers)

When publishing a new `:dialup` version to Hex, use the **publish-new-version** skill
(`.cursor/skills/publish-new-version/SKILL.md`). It requires pre-publish verification of:

1. **mix docs** — `mix.exs` extras, `lib/` moduledocs, and `guides/` match the framework
2. **dialup-site** — `site/lib/app/docs/` pages match the framework (separate source from guides)

Do not run `mix hex.publish` until both gates pass and validation commands succeed.
