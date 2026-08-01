---
paths:
  - "lib/seshat_web/**"
  - "test/seshat_web/**"
---

# Phoenix HTTP rules

Seshat has no browser UI. Phoenix/Bandit exists only to host the streamable
HTTP MCP endpoint.

- Keep `/mcp` free of an `:accepts` pipeline. The same endpoint serves JSON-RPC
  `POST` requests and SSE `GET` streams; the Anubis plug negotiates both.
- Keep the endpoint JSON-only. Do not add sessions, CSRF, static assets,
  LiveView, HTML layouts, frontend build tools, or LiveDashboard unless a new
  user-facing web product is explicitly planned.
- Seshat has no OAuth. MCP clients probe `/.well-known/*`, which must continue
  to return the explicit quiet response from `SeshatWeb.Plugs.NoAuthDiscovery`.
- Router scopes can prefix module aliases. Check the scope before writing a
  fully qualified plug or controller name.
- Use `Req` for outbound HTTP integrations; do not add another HTTP client.
