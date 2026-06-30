# Agent pitfalls (Dialup)

This guide records **common misunderstandings** coding agents make when working on Dialup apps.
Add a new section here whenever a review or production issue reveals a pattern agents get wrong.

---

## 1. `layout.css` classes already apply on every page

### The mistake

An agent sees page-specific CSS such as `agent_demo/page.css` and assumes that **each page only has access to its own `page.css`**. It then reimplements shared UI (buttons, code blocks, shadows) with new selectors like `.mcp-handoff-btn` or `.mcp-add button`.

### The reality

Dialup **colocation CSS** works like this:

1. `layout.css` (next to `layout.ex`) defines styles shared by all pages under that layout.
2. `page.css` (next to `page.ex`) adds **page-specific** rules only.
3. At render time, the framework injects **both** into one `<style data-dialup-css>` block.

DOM structure:

```html
<div class="d-layout">      <!-- layout.css scope -->
  <nav>...</nav>
  <main>
    <div class="d-page">  <!-- page.css scope -->
      ... page content ...
    </div>
  </main>
</div>
```

Layout wraps the page. Classes from `layout.css` — for example `.btn`, `.btn-primary`, `.btn-ghost` — match elements **inside any page** as long as you put the class on the element.

There is **no separate import step** and **no UI component module** required. Reuse is class-based:

```heex
<.dialup_action navigate="/docs" class="btn btn-ghost">Get Started</.dialup_action>
<button type="submit" class="btn btn-ghost">Submit</button>
<button type="button" class="btn btn-ghost btn-block" data-mcp="handoff">Hand off</button>
```

### What belongs where

| File | Use for |
|------|---------|
| `layout.css` | Site-wide tokens, buttons (`.btn*`), nav, docs chrome, shared utilities (`.btn-block`, `.btn-sm`) |
| `page.css` | Layout and content **unique to that page** (grids, cards, domain-specific regions) — not another copy of button styles |

### How to avoid it

Before adding button CSS to `page.css`, check `layout.css` for existing `.btn` variants. Prefer:

- `.btn.btn-ghost` — purple CTA
- `.btn.btn-primary` — light background
- `.btn.btn-accent` — accent2 highlight
- `.btn.btn-sm` — compact control
- `.btn.btn-block` — full width

Add a **new variant in `layout.css`** only when the design system genuinely needs one, not per page.

### Reference implementation

See `site/lib/app/layout.css` (definitions) and `site/lib/app/agent_demo/page.ex` (usage on MCP demo buttons).

---

## 2. `ws-change` inputs should not return `{:update, assigns}`

### The mistake

A text field uses `ws-change` + `ws-debounce`, but `handle_event/3` returns `{:update, assigns}`. Every debounced keystroke triggers a full `#dialup-root` morph. The input has `value={@field}` from the server, so the cursor jumps and characters disappear — especially on deployed sites with higher WebSocket latency.

### The reality

For live typing, follow [Events — ws-change](./events.md):

- Human input over `ws-change` → `{:noreply, assigns}` (state only, no DOM replace)
- Optional feedback elsewhere → `{:patch, id, html, assigns}` on a **different** element (see `/demo` `draft_change`)
- Agent-only updates that must refresh the field → `{:patch, input_id, render_input(assigns), assigns}`

### Reference implementation

`site/lib/app/agent_demo/page.ex` — `set_project/3`  
`site/lib/app/demo/page.ex` — `draft_change/3`

---

## 3. Browser join is not complete when the URL opens

### The mistake

Documentation or UI copy says that opening `browserUrl` (with `?_join=TOKEN`) immediately sets the
session cookie and attaches the human to the agent session. Agents or integrators skip
`/_dialup/finalize-join` or omit `tab_id` on the WebSocket upgrade.

### The reality

Browser handoff has one completion point:

1. **Attach** — WebSocket `/ws?tab_id=…&join_token=…` reserves the token and streams live HTML plus
   `join_finalize_nonce`. No `dialup_session` cookie yet.
2. **Complete** — `POST /_dialup/finalize-join?tab_id=…&nonce=…` sets the cookie and consumes the
   token (single-use).
3. **Sync** — `__reconnect` on the WebSocket (or cookie-only reconnect if the socket dropped after
   finalize).

`dialup.js` implements this sequence. Custom clients must too.

### How to avoid it

- Do not set the session cookie on the initial GET for join links.
- Require `tab_id` on join WebSocket upgrades.
- Treat `issue_browser_url` tokens as consumed only after finalize-join succeeds.

See [Session tokens for HTTP MCP](./agent-handoff.md).

---

## 4. A `command` action shadows legacy `handle_event/3` for the same name

### The mistake

A page keeps `handle_event("increment", ...)` and adds
`<.dialup_action command={{Ordering, :increment}}>`. The agent and human UI call the command path;
the `handle_event/3` clause is never reached for that event name.

### How to avoid it

- Remove the legacy handler when migrating to `command` mode, or use a different action name.
- Prefer `command` for Commanded-backed mutations so dispatch and remount stay in the framework.

---

## 5. `bind={...}` and `set={...}` are evaluated at render time

### The mistake

Docs or mental models treat `bind={%{order_id: @order.id}}` as compile-time metadata. The bind map
is recorded when the page **renders**, using current assigns — same as `set={%{sidebar_open: !@sidebar_open}}`.

### The reality

- `bind` values come from the latest render (via `BindActions`); dispatch reads that snapshot.
- If a command button is not rendered (`:if={false}`), bind may fall back to empty compile-time metadata.
- Keep `available={...}` aligned so agents do not call tools for off-screen actions.

See [Building agent-native applications](./agent-native-app-development.md).
