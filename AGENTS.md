# Coding-agent guidance for Dialup

When implementing a Dialup application, read these in order:

1. `guides/agent-native-app-development.md`
2. `guides/agent-handoff.md`
3. `examples/handoff_demo/lib/app/page.ex`

Treat the page's server-side session as the single source of truth. Do not create a
separate agent API or duplicate business logic.

For agent-enabled pages:

- declare state-changing operations with `<.dialup_action>`;
- implement them once in `handle_event/3`;
- add `__available__/2` predicates for live server-side availability;
- use `<.dialup_region>` for stable domain areas, structured data, and action relationships;
- expose an allowlisted projection through `agent_state/1`;
- explain goals and safety through `agent_message/1`;
- grant the minimum capabilities and projections through `agent_grant/1`;
- require human confirmation for irreversible or externally visible effects;
- test stale versions, handoff URL isolation, focus, spatial selection, and approval.

Ordinary URLs describe the application but do not attach to an existing user's browser
session. Existing work requires a user-generated `/agent/...` handoff URL.
