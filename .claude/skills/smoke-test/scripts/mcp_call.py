#!/usr/bin/env python3
"""Drive the streamable HTTP MCP endpoint over a real handshake.

Why not just use the tools in this conversation: a client caches `tools/list`
at connect, so after a server restart your cached list is the *old* schema and
proves nothing. This is also how you tell "the server is wrong" from "my client
is stale" — the distinction that otherwise costs twenty minutes.

    python3 .claude/skills/smoke-test/scripts/mcp_call.py list
    python3 .claude/skills/smoke-test/scripts/mcp_call.py stats
    python3 .claude/skills/smoke-test/scripts/mcp_call.py schema set_mixer pan
    python3 .claude/skills/smoke-test/scripts/mcp_call.py call set_mixer '{"track": 0, "pan": 2.0}'

`stats` measures the *client-visible* contract: it compact-encodes the tool
array exactly as it came off the handshake and prints the count, the total
bytes, and the largest single tool. That is the number the context budget
actually pays, which an Elixir-side approximation over `Definitions` is not —
it never sees the JSON Schema conversion or the wire encoding.

`call` prints the raw JSON-RPC envelope unabridged, because the discriminator
usually *is* the envelope: a rejection that arrives as `result` with
`isError: true` is Seshat's readable message, while an `error` with `-32602` is
a bare protocol error. Collapsing them into "it failed" loses the finding.
"""

import json
import sys
import urllib.request

URL = "http://localhost:4000/mcp"
HEADERS = {
    "Content-Type": "application/json",
    "Accept": "application/json, text/event-stream",
}


def post(body, sid=None):
    headers = dict(HEADERS)
    if sid:
        headers["Mcp-Session-Id"] = sid
    request = urllib.request.Request(URL, json.dumps(body).encode(), headers)
    response = urllib.request.urlopen(request, timeout=15)
    raw = response.read().decode()
    if raw.startswith(("event:", "data:")):
        raw = [l[5:].strip() for l in raw.splitlines() if l.startswith("data:")][0]
    return json.loads(raw), response.headers.get("Mcp-Session-Id")


def connect():
    _, sid = post(
        {
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": {
                "protocolVersion": "2025-06-18",
                "capabilities": {},
                "clientInfo": {"name": "smoke", "version": "1"},
            },
        }
    )
    post({"jsonrpc": "2.0", "method": "notifications/initialized"}, sid)
    return sid


def tools(sid):
    listed, _ = post({"jsonrpc": "2.0", "id": 2, "method": "tools/list"}, sid)
    return listed["result"]["tools"]


def main(argv):
    if len(argv) < 2:
        sys.exit(__doc__)
    command, sid = argv[1], connect()

    if command == "list":
        listed = tools(sid)
        print(f"tools listed: {len(listed)}")
        print(" ".join(sorted(t["name"] for t in listed)))

    elif command == "stats":
        listed = tools(sid)
        encoded = json.dumps(listed, ensure_ascii=False, separators=(",", ":"))
        largest = max(
            listed,
            key=lambda t: len(
                json.dumps(t, ensure_ascii=False, separators=(",", ":")).encode()
            ),
        )
        largest_bytes = len(
            json.dumps(largest, ensure_ascii=False, separators=(",", ":")).encode()
        )
        print(f"tools listed: {len(listed)}")
        print(f"advertised bytes (compact JSON, as encoded here): {len(encoded.encode())}")
        print(f"largest tool: {largest['name']} ({largest_bytes} bytes)")

    elif command == "schema":
        name, prop = argv[2], argv[3] if len(argv) > 3 else None
        schema = next(t for t in tools(sid) if t["name"] == name)["inputSchema"]
        print(json.dumps(schema["properties"][prop] if prop else schema, indent=2))

    elif command == "call":
        name = argv[2]
        arguments = json.loads(argv[3]) if len(argv) > 3 else {}
        reply, _ = post(
            {
                "jsonrpc": "2.0",
                "id": 3,
                "method": "tools/call",
                "params": {"name": name, "arguments": arguments},
            },
            sid,
        )
        print(json.dumps(reply, indent=2))

    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main(sys.argv)
