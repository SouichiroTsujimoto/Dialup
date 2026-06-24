# Session tokens for HTTP MCP

This guide covers how an external agent reaches a **live** Dialup browser session over HTTP MCP.

For the full API reference — discovery, `tools/list`, `tools/call`, grants, and metadata — read
[HTTP MCP API](./mcp-api.md) first.

## Ordinary URL vs session token

| URL | Purpose |
|-----|---------|
| `https://app.example.com/invoices` | Describes the app and static tool catalog via discovery |
| `POST /agent/{token}` | Operates one specific live session (bearer credential) |

Opening the ordinary URL in an agent's own browser creates that browser's session. It does not
attach to work already open in the user's tab.

## Obtaining a token

### From server code

```elixir
{:ok, descriptor} =
  Dialup.Session.grant(session_pid,
    capabilities: :all,
    projections: [:state, :regions, :actions],
    expires_in: :timer.minutes(15),
    require_version: true
  )

token = descriptor["token"]
endpoint = descriptor["endpoint"]  # "/agent/{token}"
```

### From the user's open tab

When the user already has the app open, issue a token tied to that tab's registry key:

```bash
curl -X POST 'https://app.example.com/_dialup/agent-handoff?tab_id=TAB_ID' \
  -H 'Cookie: dialup_session=SESSION_ID'
```

The response includes `token`, `endpoint`, and `grant` metadata. Pass `endpoint` to your MCP client.

In browser JavaScript (same origin), use `Dialup.tabId` from `dialup.js`:

```javascript
const res = await fetch(`/_dialup/agent-handoff?tab_id=${encodeURIComponent(Dialup.tabId)}`, {
  method: "POST",
  credentials: "same-origin",
});
const { token, endpoint } = await res.json();
```

## Calling the API

```bash
curl -X POST "https://app.example.com/agent/TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"read_scene","arguments":{}}}'
```

See [HTTP MCP API](./mcp-api.md) for the complete method list, versioning rules, and error codes.

## Revocation and expiry

- `DELETE /agent/:token` — revoke the grant
- `Dialup.Session.revoke(session_pid, token)` — same from Elixir
- Expired tokens return JSON-RPC error `-32002`

Ask the user to issue a fresh token from their still-open tab if a grant expires mid-task.

## Runnable example

```bash
cd examples/handoff_demo
mix run --no-halt
python3 agent.py http://localhost:4100/agent/TOKEN
```

The demo page mints a token via `Dialup.Session.grant/2`. Production apps typically combine
programmatic grants with the handoff endpoint for user-initiated access.
