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

## Agent-first session (no browser tab yet)

Sometimes the agent starts work before a human opens the app. Start a headless session from the
page URL:

```bash
curl -X POST 'https://app.example.com/_dialup/agent-session' \
  -H 'Content-Type: application/json' \
  -d '{"path":"/invoices"}'
```

The response includes `token`, `endpoint`, `grant`, `path`, and `sessionId`. Use the token with
`POST /mcp` or `POST /agent/{token}` exactly like a handoff token.

From Elixir:

```elixir
{:ok, descriptor} = Dialup.Session.start(MyApp, "/invoices")
token = descriptor["token"]
endpoint = descriptor["endpoint"]
```

Headless sessions stay alive for 15 minutes while waiting for a browser to join. After a human
connects, the normal WebSocket timeout rules apply.

## Inviting a human to join (browser handoff)

When an agent has already started or taken over a session, it can mint a one-time browser URL for a
human to open:

```json
{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"issue_browser_url","arguments":{}}}
```

The tool result includes:

- `browserUrl` — relative URL such as `/invoices?_join=TOKEN`
- `browserToken` — the raw join token
- `expiresInMs` — time until the token expires (default five minutes)

Share `browserUrl` with the person who should join. When they open it:

1. The server sets the `dialup_session` cookie for the target session.
2. The browser connects over WebSocket with the join token.
3. The human sees the same live state the agent has been operating.

The join token is **single-use**. Issue a fresh URL if it is consumed or expires.

Grant the capability explicitly when you scope agent authority:

```elixir
def agent_grant(_assigns) do
  %{
    capabilities: [:add_item, :issue_browser_url],
    projections: [:state, :regions, :actions]
  }
end
```

From Elixir on the server:

```elixir
{:ok, %{"browserUrl" => url}} = Dialup.Session.browser_url(session_pid)
```

### Security notes

- Treat `browserUrl` like a short-lived login link. Do not log it or paste it into public channels.
- A consumed or expired join token cannot be reused.
- The human regains full UI control unless the agent has called `lock_ui`.

## Live example

See the [agent handoff demo](https://dialup-framework.org/agent_demo) on dialup-framework.org.

The demo page mints a token via `Dialup.Session.grant/2`. Production apps typically combine
programmatic grants with the handoff endpoint for user-initiated access.
