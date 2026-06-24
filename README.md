# Dialup (English)

**WebSocket-first apps** and **auto-generated HTTP MCP APIs** in one file-based Elixir framework.

[日本語](./README.ja.md)

## Links

- [Official website](https://dialup-framework.org/)
- [Getting Started guide](https://dialup.hexdocs.pm/getting-started.html)

## Overview

Dialup is an Elixir framework for building live applications with a Next.js-like developer
experience. It has two equal promises: the human UI is WebSocket-first from the first render, and
the HTTP MCP API is generated from the same page declarations. Each page is one supervised
server-side actor. You write the UI once with `<.dialup_action>` and `<.dialup_region>`; Dialup
derives `tools/list`, `tools/call`, and `read_scene` from those declarations. No duplicate REST
layer. No hand-written OpenAPI for agent tools.

```
Human browser  ──WebSocket──►  UserSessionProcess  ◄──HTTP JSON-RPC──  AI agent
                                      │
                               handle_event/3
                                      │
                          declare_action / dialup_action
```

### Features

- **WebSocket-first human UI** — live DOM updates over `/ws` with idiomorph
- **Auto-generated HTTP MCP API** — actions and regions become agent tools automatically
- **One event path** — browser events and agent `tools/call` requests share `handle_event/3`
- **HTTP MCP request-response** — `initialize`, `tools/list`, `tools/call` at `POST /agent/:token`
- **Agent discovery** — `/.well-known/dialup-agent`, embedded page context, `/llms.txt`
- **Scoped session tokens** — least-privilege grants with expiry and projection control
- **File-based routing** — file placement maps directly to URLs
- **Server-side state** — one tab = one `UserSessionProcess`
- **Colocated CSS** — `.css` next to `.ex`, auto-scoped at compile time

## Quick Start

### 1. Install the generator

```bash
mix archive.install hex dialup_new
```

### 2. Create a new project

```bash
mix dialup.new my_app
cd my_app
mix deps.get
mix run --no-halt
```

Then visit http://localhost:4000

### Agent-ready page in 30 lines

```elixir
defmodule Dialup.App.Page do
  use Dialup.Page

  declare_action name: :increment, desc: "Increment counter", params: %{}

  def mount(_params, assigns), do: {:ok, Map.put(assigns, :count, 0)}
  def agent_state(assigns), do: %{count: assigns.count}

  def handle_event(:increment, _, assigns) do
    {:update, Map.update!(assigns, :count, &(&1 + 1))}
  end

  def render(assigns) do
    ~H"""
    <p>Count: {@count}</p>
    <.dialup_action name={:increment}>+1</.dialup_action>
    """
  end
end
```

The same `<.dialup_action>` is a WebSocket-backed browser button and a generated MCP tool. Use the
page from the browser, or grant a session token and call the API:

```bash
# After obtaining a token (see guides/mcp-api.md)
curl -X POST http://localhost:4000/agent/TOKEN \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"read_scene","arguments":{}}}'
```

## Documentation

Run `mix docs --open` to browse the full documentation locally.

- [Events](./guides/events.md) — **WebSocket-first UI events and updates**
- [HTTP MCP API](./guides/mcp-api.md) — **auto-generated tools, discovery, versioning**
- [Building agent-native apps](./guides/agent-native-app-development.md) — implementation workflow
- [Session tokens](./guides/agent-handoff.md) — reaching a live browser session
- [Getting Started](./guides/getting-started.md) — installation and basics
- [Fullstack Example](./guides/fullstack-example.md) — Ecto and PubSub

See `guides/` for routing, state, lifecycle, events, deployment, and more.

## Architecture

```
Browser (human)     AI agent (MCP client)
     |                      |
dialup.js ──WS──► UserSessionProcess ◄──POST /agent/:token──
     |                      |
 idiomorph              render/1 + handle_event/3
                             |
                    declare_action / dialup_region
                             │
                      tools/list (HTTP)
```

## License

MIT
