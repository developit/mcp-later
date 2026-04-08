#!/usr/bin/env bash
# mcp-later - Lazy-spawning proxy for MCP stdio servers.
# Caches discovery responses (tools/list, prompts/list, etc.) to disk
# and only spawns the real server when actual work is requested.

set -uo pipefail

MCP_LATER_CACHE_DIR="${MCP_LATER_CACHE_DIR:-$HOME/.cache/mcp-later}"
MCP_LATER_TTL="${MCP_LATER_TTL:-86400}"

debug() { [ -n "${MCP_LATER_DEBUG:-}" ] && printf '[mcp-later] %s\n' "$*" >&2 || true; }

# ── Cleanup ──────────────────────────────────────────────────────────
TMP=""

cleanup() {
  trap - EXIT INT TERM
  # Kill the server process explicitly (jobs -p may miss it during wait).
  [ -n "${SVR_PID:-}" ] && kill "$SVR_PID" 2>/dev/null
  kill $(jobs -p) 2>/dev/null || true
  wait 2>/dev/null || true
  [ -n "$TMP" ] && rm -rf "$TMP"
  true
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# ── Arguments ────────────────────────────────────────────────────────
usage() {
  cat >&2 <<'EOF'
mcp-later - lazy MCP server proxy

Wraps an MCP stdio server, caching discovery responses (tools/list,
prompts/list, etc.) to disk and deferring server startup until a
non-cached request arrives.

Usage:
  mcp-later <command> [args...]            Proxy mode
  mcp-later --warmup <command> [args...]   Pre-populate cache
  mcp-later --help                         Show this help

Environment:
  MCP_LATER_CACHE_DIR  Cache directory (default: ~/.cache/mcp-later)
  MCP_LATER_TTL        Cache lifetime in seconds (default: 86400)
  MCP_LATER_DEBUG      Enable debug logging to stderr

Example (Claude Code config):
  {
    "mcpServers": {
      "browser-mcp": {
        "command": "mcp-later",
        "args": ["npx", "@browsermcp/mcp@latest"]
      }
    }
  }
EOF
}

WARMUP=0
case "${1:-}" in
  --warmup) WARMUP=1; shift ;;
  -h|--help) usage; exit 0 ;;
esac
if [ $# -eq 0 ]; then
  usage; exit 1
fi
SERVER_CMD=("$@")

# ── Cache paths ──────────────────────────────────────────────────────
CACHE_KEY=$(printf '%s\0' "${SERVER_CMD[@]}" | shasum -a 256 | cut -d' ' -f1)
mkdir -p "$MCP_LATER_CACHE_DIR"

C_INIT="$MCP_LATER_CACHE_DIR/$CACHE_KEY.init"
C_TOOLS="$MCP_LATER_CACHE_DIR/$CACHE_KEY.tools"
C_PROMPTS="$MCP_LATER_CACHE_DIR/$CACHE_KEY.prompts"
C_RESOURCES="$MCP_LATER_CACHE_DIR/$CACHE_KEY.resources"

# ── Cache freshness ─────────────────────────────────────────────────
cache_ok() {
  [ -f "$1" ] || return 1
  local mod now
  mod=$(stat -f%m "$1" 2>/dev/null || stat -c%Y "$1" 2>/dev/null) || return 1
  now=$(date +%s)
  [ $(( now - mod )) -lt "$MCP_LATER_TTL" ]
}

# ── JSON helpers (no jq needed) ──────────────────────────────────────
# Extract the "method" string from a JSON-RPC message.
# Uses awk index() to find the first occurrence, avoiding greedy-match bugs.
jmethod() {
  awk '{
    i = index($0, "\"method\"")
    if (!i) exit
    s = substr($0, i + 9)
    gsub(/^[ \t:]+/, "", s)
    if (substr(s, 1, 1) != "\"") exit
    s = substr(s, 2)
    j = index(s, "\"")
    if (j) print substr(s, 1, j - 1)
  }' <<< "$1"
}

# Extract the "id" value (number or quoted string) from a JSON-RPC message.
jid() {
  awk '{
    i = index($0, "\"id\"")
    if (!i) exit
    s = substr($0, i + 4)
    gsub(/^[ \t:]+/, "", s)
    if (substr(s, 1, 1) == "\"") {
      s = substr(s, 2)
      j = index(s, "\"")
      if (j) print "\"" substr(s, 1, j - 1) "\""
    } else {
      match(s, /^[0-9]+/)
      if (RLENGTH > 0) print substr(s, 1, RLENGTH)
    }
  }' <<< "$1"
}

# Build a JSON-RPC success response.
jresp() { printf '{"jsonrpc":"2.0","id":%s,"result":%s}\n' "$1" "$2"; }

# Extract the "result" value from a JSON-RPC response.
# Tracks brace/bracket depth to correctly handle nested objects.
jresult() {
  awk '{
    i = index($0, "\"result\"")
    if (!i) { print "null"; exit 1 }
    s = substr($0, i + 9)
    gsub(/^[ \t:]+/, "", s)
    d = 0; st = 0; q = 0; esc = 0
    for (j = 1; j <= length(s); j++) {
      c = substr(s, j, 1)
      if (esc) { esc = 0; continue }
      if (c == "\\") { esc = 1; continue }
      if (c == "\"") { q = !q; continue }
      if (q) continue
      if (c == "{" || c == "[") { if (!d) st = j; d++ }
      else if (c == "}" || c == "]") { d--; if (!d) { print substr(s, st, j - st + 1); exit 0 } }
    }
    print "null"; exit 1
  }' <<< "$1"
}

# Check if a JSON-RPC response is an error.
jerror() { [[ "$1" == *'"error"'* ]]; }

# ── Server I/O ───────────────────────────────────────────────────────
start_server() {
  TMP=$(mktemp -d)
  mkfifo "$TMP/in" "$TMP/out"
  "${SERVER_CMD[@]}" < "$TMP/in" > "$TMP/out" &
  SVR_PID=$!
  exec 3>"$TMP/in" 4<"$TMP/out"
  debug "server started pid=$SVR_PID"
}

svr_send() {
  debug "-> $1"
  printf '%s\n' "$1" >&3
}

# Read lines from the server until a response with the given id arrives.
# Non-matching lines (notifications) are silently skipped.
svr_read_id() {
  local want="$1" line
  while IFS= read -r -t 30 line <&4; do
    debug "<- $line"
    local got
    got=$(jid "$line")
    [ "$got" = "$want" ] && { printf '%s' "$line"; return 0; }
  done
  return 1
}

svr_stop() {
  exec 3>&- 2>/dev/null || true
  exec 4<&- 2>/dev/null || true
  [ -n "$SVR_PID" ] && kill "$SVR_PID" 2>/dev/null
  wait "$SVR_PID" 2>/dev/null || true
  SVR_PID=""
  [ -n "$TMP" ] && rm -rf "$TMP"
  TMP=""
}

# ── Warmup: discover and cache server capabilities ───────────────────
do_warmup() {
  debug "warmup start"
  start_server

  # initialize
  svr_send '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"mcp-later","version":"0.1.0"}}}'
  local r
  r=$(svr_read_id 1) || { debug "warmup: init failed"; svr_stop; return 1; }
  if ! jerror "$r"; then
    jresult "$r" > "$C_INIT"
    debug "cached init"
  else
    debug "warmup: init returned error"
    svr_stop; return 1
  fi

  svr_send '{"jsonrpc":"2.0","method":"notifications/initialized"}'

  # tools/list
  svr_send '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'
  r=$(svr_read_id 2) || { debug "warmup: tools/list timeout"; svr_stop; return 1; }
  if ! jerror "$r"; then
    jresult "$r" > "$C_TOOLS"
    debug "cached tools/list"
  else
    printf '{"tools":[]}' > "$C_TOOLS"
  fi

  # prompts/list
  svr_send '{"jsonrpc":"2.0","id":3,"method":"prompts/list","params":{}}'
  r=$(svr_read_id 3) || { debug "warmup: prompts/list timeout"; svr_stop; return 1; }
  if ! jerror "$r"; then
    jresult "$r" > "$C_PROMPTS"
    debug "cached prompts/list"
  else
    printf '{"prompts":[]}' > "$C_PROMPTS"
  fi

  # resources/list (optional -- server may not support it)
  svr_send '{"jsonrpc":"2.0","id":4,"method":"resources/list","params":{}}'
  r=$(svr_read_id 4) || r=""
  if [ -n "$r" ] && ! jerror "$r"; then
    jresult "$r" > "$C_RESOURCES"
    debug "cached resources/list"
  else
    printf '{"resources":[]}' > "$C_RESOURCES"
  fi

  svr_stop
  debug "warmup done"
}

# ── Warmup-only mode ─────────────────────────────────────────────────
if [ "$WARMUP" -eq 1 ]; then
  do_warmup
  exit $?
fi

# ── Proxy mode ───────────────────────────────────────────────────────
CLIENT_INIT=""

# Serve a cached response, or fall back to a default.
serve() {
  local file="$1" id="$2" fallback="$3"
  if cache_ok "$file"; then
    debug "hit $file"
    jresp "$id" "$(cat "$file")"
  else
    debug "miss $file"
    jresp "$id" "$fallback"
  fi
}

# Transition to passthrough: spawn the real server and become a pipe.
passthrough() {
  local trigger="$1"
  debug "passthrough start"
  start_server

  # Replay the client's initialize handshake with the real server.
  local init_req
  if [ -n "$CLIENT_INIT" ]; then
    init_req="$CLIENT_INIT"
  else
    init_req='{"jsonrpc":"2.0","id":9999,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"mcp-later","version":"0.1.0"}}}'
  fi
  local init_id
  init_id=$(jid "$init_req")

  svr_send "$init_req"
  svr_read_id "$init_id" > /dev/null || true
  svr_send '{"jsonrpc":"2.0","method":"notifications/initialized"}'

  # Forward the request that triggered passthrough.
  svr_send "$trigger"

  # Bidirectional pipe: server stdout → our stdout, our stdin → server stdin.
  # Both cats are backgrounded so cleanup can kill them via `jobs -p`.
  # Each closes the fd it doesn't use so the server gets proper EOF.
  cat <&4 3>&- &
  local bg_out=$!
  cat <&0 >&3 4<&- &
  local bg_in=$!
  wait $bg_in 2>/dev/null || true
  exec 3>&-   # signal EOF to server stdin
  wait $bg_out 2>/dev/null || true
}

# ── Main loop (Phase 1: serve from cache) ────────────────────────────
while IFS= read -r line; do
  [ -z "$line" ] && continue
  method=$(jmethod "$line")
  debug "method=$method"

  case "$method" in
    initialize)
      CLIENT_INIT="$line"
      id=$(jid "$line")
      if ! cache_ok "$C_INIT"; then
        debug "cold cache, running inline warmup"
        do_warmup
      fi
      serve "$C_INIT" "$id" \
        '{"protocolVersion":"2024-11-05","capabilities":{"tools":{},"prompts":{}},"serverInfo":{"name":"mcp-later","version":"0.1.0"}}'
      ;;
    notifications/initialized)
      # No response needed.
      ;;
    tools/list)
      serve "$C_TOOLS" "$(jid "$line")" '{"tools":[]}'
      ;;
    prompts/list)
      serve "$C_PROMPTS" "$(jid "$line")" '{"prompts":[]}'
      ;;
    resources/list)
      serve "$C_RESOURCES" "$(jid "$line")" '{"resources":[]}'
      ;;
    ping)
      jresp "$(jid "$line")" '{}'
      ;;
    *)
      # Non-cacheable request: spawn the real server and hand off.
      passthrough "$line"
      exit 0
      ;;
  esac
done
