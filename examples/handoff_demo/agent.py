#!/usr/bin/env python3
import json
import sys
import urllib.request


def post(endpoint, payload):
    request = urllib.request.Request(
        endpoint,
        data=json.dumps(payload).encode(),
        headers={"content-type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(request) as response:
        return json.load(response)


def tools_call(endpoint, request_id, name, arguments=None):
    return post(
        endpoint,
        {
            "jsonrpc": "2.0",
            "id": request_id,
            "method": "tools/call",
            "params": {"name": name, "arguments": arguments or {}},
        },
    )


if len(sys.argv) != 2:
    raise SystemExit("usage: python3 agent.py http://localhost:4100/agent/TOKEN")

endpoint = sys.argv[1]

post(
    endpoint,
    {
        "jsonrpc": "2.0",
        "id": 0,
        "method": "initialize",
        "params": {
            "protocolVersion": "2025-11-25",
            "capabilities": {},
            "clientInfo": {"name": "handoff-demo", "version": "1"},
        },
    },
)

tools = post(endpoint, {"jsonrpc": "2.0", "id": 1, "method": "tools/list", "params": {}})
print("Tools:", [tool["name"] for tool in tools["result"]["tools"]])

scene = tools_call(endpoint, 2, "read_scene")
content = scene["result"]["structuredContent"]
print("Scene:", json.dumps(content, indent=2))
version = content["version"]

result = tools_call(
    endpoint, 3, "add_item", {"sku": "AI-ITEM", "qty": 2, "_version": version}
)
print("After add_item:", json.dumps(result["result"]["structuredContent"], indent=2))
