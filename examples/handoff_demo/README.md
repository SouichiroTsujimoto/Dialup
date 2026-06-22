# Human → AI handoff demo

Start the app:

```bash
cd examples/handoff_demo
mix deps.get
mix run --no-halt
```

Open <http://localhost:4100>, optionally click **Add HUMAN-ITEM**, then click
**AIに引き継ぐ / Hand off to AI** at the bottom-right and copy the generated session URL
from the page. Pass that URL to the bundled agent:

```bash
python3 agent.py http://localhost:4100/agent/TOKEN
```

The agent reads the state created by the human, focuses the invoice region in the browser,
and adds `AI-ITEM` to the same live session. The browser updates without a reload.

The page grant expires after 15 minutes. `Submit` demonstrates the approval gate: an agent
call opens a browser dialog, and the pending action runs only after the human approves it.

The normal page URL also advertises an invisible agent discovery document:

```bash
curl 'http://localhost:4100/.well-known/dialup-agent?path=%2F'
```

Its message explains the demo concept, the difference between ordinary and handoff URLs,
and the recommended operation sequence.
