#!/usr/bin/env python3
import json
import sys
import time
import urllib.request


def call(endpoint, request_id, name, arguments=None):
    payload = {
        "jsonrpc": "2.0",
        "id": request_id,
        "method": "tools/call",
        "params": {"name": name, "arguments": arguments or {}},
    }
    request = urllib.request.Request(
        endpoint,
        data=json.dumps(payload).encode(),
        headers={"content-type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(request) as response:
        return json.load(response)


if len(sys.argv) != 2:
    raise SystemExit("usage: python3 agent.py http://localhost:4100/agent/TOKEN")

endpoint = sys.argv[1]
scene = call(endpoint, 1, "read_scene")
print("Observed shared state:", json.dumps(scene["result"]["structuredContent"], indent=2))
version = scene["result"]["structuredContent"]["version"]

call(endpoint, 2, "focus", {"target": "item_list"})
time.sleep(1)

result = call(endpoint, 3, "add_item", {"sku": "AI-ITEM", "qty": 2, "_version": version})
print("AI action complete:", json.dumps(result["result"]["structuredContent"], indent=2))
