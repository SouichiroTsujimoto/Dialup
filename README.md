# Dialup (English)

WebSocket-first, file-based routing Elixir framework.

[日本語](./README.ja.md)

## Overview

Dialup is an Elixir framework for building WebSocket-first applications with a Next.js-like developer experience.

### Features

- **File-based routing** — file placement maps directly to URLs
- **WebSocket-first** — real-time communication built in
- **Server-side state** — no client-side state management needed
- **Simple architecture** — lighter than Phoenix/LiveView
- **Colocated CSS** — `.css` files next to `.ex` files, auto-scoped at compile time
- **Static file serving** — `priv/static/` served automatically
- **WebSocket origin verification** — cross-origin connection protection built in

## Quick Start

### Installation

```elixir
# mix.exs
def deps do
  [
    {:dialup, "~> 0.1.0"}
  ]
end
```

### Generated project structure

```
my_app/
├── mix.exs
├── lib/
│   ├── my_app.ex          # Application entry point
│   ├── root.html.heex     # HTML shell — customize <head>, hooks, analytics
│   └── app/
│       ├── layout.ex / layout.css   # Root layout
│       ├── page.ex   / page.css     # Home page at /
│       └── error.ex  / error.css    # Error page (404, 500)
└── priv/static/           # Static assets (images, fonts, favicon)
```

### Minimal app

```elixir
# lib/my_app.ex
defmodule MyApp do
  use Application
  use Dialup, app_dir: __DIR__ <> "/app"

  def start(_type, _args) do
    children = [
      {Dialup, app: __MODULE__, port: 4000}
    ]
    Supervisor.start_link(children, strategy: :one_for_one, name: __MODULE__.Supervisor)
  end
end
```

```elixir
# lib/app/page.ex
defmodule MyApp.Page do
  use Dialup.Page

  def mount(_params, assigns) do
    {:ok, set_default(%{count: 0}, assigns)}
  end

  def handle_event("increment", _value, assigns) do
    {:update, Map.update!(assigns, :count, &(&1 + 1))}
  end

  def render(assigns) do
    ~H"""
    <h1>Hello Dialup</h1>
    <p>Count: {@count}</p>
    <button ws-event="increment">+</button>
    """
  end
end
```

## Documentation

Run `mix docs --open` to browse the full documentation locally.

Guide source files live in `guides/`:

- [Getting Started](./guides/getting-started.md) — installation and basic usage
- [Routing](./guides/routing.md) — routing in depth
- [State Management](./guides/state-management.md) — managing server-side state
- [Lifecycle](./guides/lifecycle.md) — page lifecycle hooks
- [Events](./guides/events.md) — handling events
- [Helpers](./guides/helpers.md) — helper functions
- [Deployment](./guides/deployment.md) — deploying to production
- [Fullstack Example](./guides/fullstack-example.md) — a practical app using Ecto and PubSub

## Architecture

```
Browser          Elixir Server
   |                    |
dialup.js ←──WS──→ UserSessionProcess (1 tab = 1 process)
   |                    |
idiomorph            render/1
                        |
                     assigns (state)
```

## License

MIT
