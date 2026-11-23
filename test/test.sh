#!/usr/bin/env bash
# Tests for mcp-later. Run from the repo root: bash test/test.sh
set -uo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
MCP_LATER="$DIR/../mcp-later.sh"
MOCK="bash $DIR/mock-server.sh"
CACHE=$(mktemp -d)
PASS=0 FAIL=0

cleanup() { rm -rf "$CACHE"; }
trap cleanup EXIT

# ── Helpers ──────────────────────────────────────────────────────────
run_mcp-later() { MCP_LATER_CACHE_DIR="$CACHE" bash "$MCP_LATER" $MOCK; }
warm()     { MCP_LATER_CACHE_DIR="$CACHE" bash "$MCP_LATER" --warmup $MOCK 2>/dev/null; }

send() {
  # Send JSON-RPC messages to mcp-later, capture stdout.
  local input=""
  for msg in "$@"; do input+="$msg"$'\n'; done
  printf '%s' "$input" | run_mcp-later 2>/dev/null
}

assert_contains() {
  local label="$1" haystack="$2" needle="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    PASS=$((PASS + 1))
    printf '  \033[32m✓\033[0m %s\n' "$label"
  else
    FAIL=$((FAIL + 1))
    printf '  \033[31m✗\033[0m %s\n' "$label"
    printf '    expected to contain: %s\n' "$needle"
    printf '    got: %s\n' "$haystack"
  fi
}

assert_not_contains() {
  local label="$1" haystack="$2" needle="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    PASS=$((PASS + 1))
    printf '  \033[32m✓\033[0m %s\n' "$label"
  else
    FAIL=$((FAIL + 1))
    printf '  \033[31m✗\033[0m %s\n' "$label"
    printf '    expected NOT to contain: %s\n' "$needle"
  fi
}

assert_eq() {
  local label="$1" actual="$2" expected="$3"
  if [ "$actual" = "$expected" ]; then
    PASS=$((PASS + 1))
    printf '  \033[32m✓\033[0m %s\n' "$label"
  else
    FAIL=$((FAIL + 1))
    printf '  \033[31m✗\033[0m %s\n' "$label"
    printf '    expected: %s\n' "$expected"
    printf '    got:      %s\n' "$actual"
  fi
}

INIT='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}'
INITIALIZED='{"jsonrpc":"2.0","method":"notifications/initialized"}'

# ── Tests ────────────────────────────────────────────────────────────

echo "warmup"
  rm -rf "$CACHE"/*
  warm
  assert_eq "creates init cache" "$([ -f "$CACHE"/*.init ] && echo yes)" "yes"
  assert_eq "creates tools cache" "$([ -f "$CACHE"/*.tools ] && echo yes)" "yes"
  assert_eq "creates prompts cache" "$([ -f "$CACHE"/*.prompts ] && echo yes)" "yes"
  assert_eq "creates resources cache" "$([ -f "$CACHE"/*.resources ] && echo yes)" "yes"
  assert_contains "init has serverInfo" "$(cat "$CACHE"/*.init)" '"serverInfo"'
  assert_contains "tools has mock_tool" "$(cat "$CACHE"/*.tools)" '"mock_tool"'

echo ""
echo "cached serving (no server spawn)"
  out=$(send \
    "$INIT" \
    "$INITIALIZED" \
    '{"jsonrpc":"2.0","id":10,"method":"tools/list","params":{}}' \
    '{"jsonrpc":"2.0","id":11,"method":"prompts/list","params":{}}' \
    '{"jsonrpc":"2.0","id":12,"method":"resources/list","params":{}}' \
  )
  assert_contains "init response has correct id" "$out" '"id":1,'
  assert_contains "init response has serverInfo" "$out" '"mock-server"'
  assert_contains "tools/list response has correct id" "$out" '"id":10,'
  assert_contains "tools/list returns cached tools" "$out" '"mock_tool"'
  assert_contains "prompts/list response has correct id" "$out" '"id":11,'
  assert_contains "resources/list response has correct id" "$out" '"id":12,'

echo ""
echo "id rewriting"
  out=$(send \
    '{"jsonrpc":"2.0","id":999,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}' \
    "$INITIALIZED" \
    '{"jsonrpc":"2.0","id":42,"method":"tools/list","params":{}}' \
  )
  assert_contains "init uses client id" "$out" '"id":999,'
  assert_contains "tools/list uses client id" "$out" '"id":42,'

echo ""
echo "passthrough (lazy spawn)"
  out=$(send \
    "$INIT" \
    "$INITIALIZED" \
    '{"jsonrpc":"2.0","id":20,"method":"tools/call","params":{"name":"mock_tool","arguments":{}}}' \
  )
  assert_contains "tools/call response received" "$out" '"id":20,'
  assert_contains "tools/call has result" "$out" '"mock result"'

echo ""
echo "multiple tool calls (second call must not hang)"
  # Pipe two tools/call requests and close stdin. Both should produce responses.
  out=$(send \
    "$INIT" \
    "$INITIALIZED" \
    '{"jsonrpc":"2.0","id":20,"method":"tools/call","params":{"name":"mock_tool","arguments":{}}}' \
    '{"jsonrpc":"2.0","id":21,"method":"tools/call","params":{"name":"mock_tool","arguments":{}}}' \
  )
  assert_contains "first tools/call response" "$out" '"id":20,'
  assert_contains "second tools/call response" "$out" '"id":21,'

echo ""
echo "cold cache (inline warmup)"
  rm -rf "$CACHE"/*
  out=$(send \
    "$INIT" \
    "$INITIALIZED" \
    '{"jsonrpc":"2.0","id":5,"method":"tools/list","params":{}}' \
  )
  assert_contains "serves init after inline warmup" "$out" '"id":1,'
  assert_contains "serves tools after inline warmup" "$out" '"mock_tool"'
  assert_eq "cache populated" "$([ -f "$CACHE"/*.tools ] && echo yes)" "yes"

echo ""
echo "TTL expiry"
  # Touch cache files to be old
  touch -t 200001010000 "$CACHE"/*.init "$CACHE"/*.tools "$CACHE"/*.prompts "$CACHE"/*.resources 2>/dev/null
  out=$(MCP_LATER_CACHE_DIR="$CACHE" MCP_LATER_DEBUG=1 bash "$MCP_LATER" $MOCK <<< "$INIT" 2>&1)
  assert_contains "stale cache triggers warmup" "$out" "cold cache"

echo ""
echo "ping"
  out=$(send \
    "$INIT" \
    "$INITIALIZED" \
    '{"jsonrpc":"2.0","id":77,"method":"ping"}' \
  )
  assert_contains "ping response has correct id" "$out" '"id":77,'

echo ""
echo "server/discover probe (no server spawn)"
  out=$(printf '%s\n' \
    '{"jsonrpc":"2.0","id":"server-discover-probe-1","method":"server/discover","params":{}}' \
    "$INIT" \
    "$INITIALIZED" \
    '{"jsonrpc":"2.0","id":10,"method":"tools/list","params":{}}' \
    | MCP_LATER_CACHE_DIR="$CACHE" MCP_LATER_DEBUG=1 bash "$MCP_LATER" $MOCK 2>&1)
  assert_contains "discover answered with method not found" "$out" '"id":"server-discover-probe-1","error":{"code":-32601'
  assert_contains "init still served from cache" "$out" '"id":1,'
  assert_contains "tools/list still served from cache" "$out" '"mock_tool"'
  assert_not_contains "real server not spawned" "$out" "passthrough start"

echo ""
echo "help"
  help_out=$(bash "$MCP_LATER" --help 2>&1)
  assert_contains "--help shows usage" "$help_out" "Usage:"
  assert_contains "--help shows env vars" "$help_out" "MCP_LATER_CACHE_DIR"
  help_out_h=$(bash "$MCP_LATER" -h 2>&1)
  assert_contains "-h also works" "$help_out_h" "Usage:"

echo ""
echo "signal handling"
  rm -rf "$CACHE"/*
  warm
  (
    printf '%s\n%s\n%s\n' \
      "$INIT" \
      "$INITIALIZED" \
      '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"mock_tool","arguments":{}}}'
    sleep 10
  ) | MCP_LATER_CACHE_DIR="$CACHE" bash "$MCP_LATER" $MOCK > /dev/null 2>&1 &
  local_pid=$!
  sleep 1
  kill $local_pid 2>/dev/null
  wait $local_pid 2>/dev/null || true
  sleep 1
  # pgrep -f also matches ancestor processes whose cmdline contains "mock-server.sh"
  # (the pipeline subshell, the test runner in some environments). Use pgrep -x to
  # match only the actual mock-server.sh interpreter process.
  if pgrep -xf "bash .*/mock-server.sh" > /dev/null 2>&1; then
    FAIL=$((FAIL + 1))
    printf '  \033[31m✗\033[0m SIGTERM cleans up server\n'
    pkill -xf "bash .*/mock-server.sh" 2>/dev/null
  else
    PASS=$((PASS + 1))
    printf '  \033[32m✓\033[0m SIGTERM cleans up server\n'
  fi

# ── Summary ──────────────────────────────────────────────────────────
echo ""
echo "──────────────────────────"
printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
