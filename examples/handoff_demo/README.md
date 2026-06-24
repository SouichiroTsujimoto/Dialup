# HTTP MCP demo

Start the app:

```bash
cd examples/handoff_demo
mix deps.get
mix run --no-halt
```

Open <http://localhost:4100>. The page mints a scoped agent token at startup (see browser devtools
or server logs). Pass the endpoint to the bundled Python client:

```bash
python3 agent.py http://localhost:4100/agent/TOKEN
```

The agent reads the live scene, calls `add_item` over HTTP JSON-RPC, and the browser updates
without a reload — the same `handle_event/3` path as a human click.

`Submit` uses `confirm: :human`. Over HTTP MCP it returns error `-32004`; use the browser button
for that operation.

## Discovery

```bash
curl 'http://localhost:4100/.well-known/dialup-agent?path=%2F'
curl 'http://localhost:4100/llms.txt'
```

## API shape

```json
{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}
{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"read_scene","arguments":{}}}
{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"add_item","arguments":{"sku":"AI-ITEM","qty":2,"_version":0}}}
```

See [HTTP MCP API](../../guides/mcp-api.md) for the full reference.
