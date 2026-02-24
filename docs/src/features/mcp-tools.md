# MCP Tools

Liteskill integrates with [Model Context Protocol (MCP)](https://modelcontextprotocol.io/) servers to give LLMs access to external tools.

## How It Works

1. Register an MCP server with its HTTP URL
2. Liteskill discovers available tools via `tools/list`
3. During conversation streaming, the LLM can request tool calls
4. Liteskill executes tool calls via `tools/call` and feeds results back

## MCP Client

`Liteskill.McpServers.Client` implements the MCP JSON-RPC 2.0 Streamable HTTP transport:

1. **Initialize** — Sends `initialize` request, receives session ID
2. **Initialized** — Sends `notifications/initialized` notification
3. **Request** — Sends `tools/list` or `tools/call` with the session ID

The client supports:

- Automatic retry with exponential backoff on 429/5xx errors
- Custom headers per server
- API key authentication (sent as `Authorization: Bearer <key>`)
- SSE response parsing

## Server Management

- Users can create, update, and delete their own MCP servers
- Global servers (set by admin) are available to all users
- Servers can be shared via ACLs

### SSRF Protection

Server URLs are validated to prevent Server-Side Request Forgery (SSRF). By default:

- Only **HTTPS** URLs are accepted
- Private and reserved addresses are blocked (`localhost`, `127.*`, `10.*`, `172.16-31.*`, `192.168.*`, `169.254.*`, IPv6 loopback, and `host.docker.internal`)

To allow private URLs (e.g. for self-hosted MCP servers), enable **Allow private MCP URLs** in server settings.

### Docker Networking

The Liteskill app container uses `network_mode: host`, which means it shares the host's network stack directly. MCP servers running on the host machine are reachable at `localhost`:

```
http://localhost:4005
```

This requires **Allow private MCP URLs** enabled in server settings, since `localhost` resolves to a private address.

## Tool Selection

Users select which MCP servers are active for their conversations. Selections are persisted in `user_tool_selections` and restored on login. Stale selections (referencing inaccessible servers) are automatically pruned.

## Built-in Tools

Liteskill provides built-in virtual MCP servers (prefixed with `builtin:`) for internal capabilities like report editing.
