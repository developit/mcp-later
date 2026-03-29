# mcp-later

One command to make MCP Servers free until they are actually used.

`mcp-later` is a lightweight proxy that wraps any [MCP](https://modelcontextprotocol.io) stdio server. It caches discovery responses (`tools/list`, `prompts/list`, etc.) to disk, and **doesn't start the real server until it's actually needed** (e.g., `tools/call`).

## The problem

Every time you start a Claude Code session, all configured MCP servers are spawned just to list their tools. If you have `browser-mcp` configured globally, Chrome gets taken over immediately -- even if you never use a browser tool.

## The fix

Wrap any MCP server command with `mcp-later`. Discovery responses are served from a local disk cache, and the real server is only started when a tool is actually invoked.

```
npm i -g mcp-later
```

> `mcp-later` is a ~300 line bash script with zero dependencies.

## Usage

### Claude Code

Change your MCP server config from this:

```json
{
  "mcpServers": {
    "browser-mcp": {
      "command": "npx",
      "args": ["@browsermcp/mcp@latest"]
    }
  }
}
```

To this:

```json
{
  "mcpServers": {
    "browser-mcp": {
      "command": "mcp-later",
      "args": ["npx", "@browsermcp/mcp@latest"]
    }
  }
}
```

That's it. Your MCP server's tools show up instantly from cache, and the real server only starts when a tool is called.

### Pre-warm the cache

On first run, `mcp-later` automatically spawns the server to populate the cache. If you want to do this ahead of time:

```sh
mcp-later --warmup npx @browsermcp/mcp@latest
```

## How it works

1. **Phase 1 (cached):** `mcp-later` responds to `initialize`, `tools/list`, `prompts/list`, and `resources/list` from disk cache. The real server is never started.

2. **Phase 2 (passthrough):** When a non-cached request arrives (e.g., `tools/call`), the real server is spawned, the init handshake is replayed, and `mcp-later` becomes a transparent bidirectional pipe for the rest of the session.

Cache files are stored in `~/.cache/mcp-later/` and expire after 24 hours by default.

## Configuration

All configuration is via environment variables:

| Variable | Default | Description |
|---|---|---|
| `MCP_LATER_CACHE_DIR` | `~/.cache/mcp-later` | Cache directory |
| `MCP_LATER_TTL` | `86400` (24h) | Cache lifetime in seconds |
| `MCP_LATER_DEBUG` | _(unset)_ | Set to any value to enable debug logging to stderr |

## License

MIT
