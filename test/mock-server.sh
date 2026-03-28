#!/usr/bin/env bash
# Mock MCP server for testing mcpz.
# Reads JSON-RPC from stdin, responds on stdout.

while IFS= read -r line; do
  method=$(awk '{
    i = index($0, "\"method\"")
    if (!i) exit
    s = substr($0, i + 9)
    gsub(/^[ \t:]+/, "", s)
    if (substr(s, 1, 1) != "\"") exit
    s = substr(s, 2)
    j = index(s, "\"")
    if (j) print substr(s, 1, j - 1)
  }' <<< "$line")

  id=$(awk '{
    i = index($0, "\"id\"")
    if (!i) exit
    s = substr($0, i + 4)
    gsub(/^[ \t:]+/, "", s)
    match(s, /^[0-9]+/)
    if (RLENGTH > 0) print substr(s, 1, RLENGTH)
  }' <<< "$line")

  case "$method" in
    initialize)
      printf '{"jsonrpc":"2.0","id":%s,"result":{"protocolVersion":"2024-11-05","capabilities":{"tools":{}},"serverInfo":{"name":"mock-server","version":"0.0.1"}}}\n' "$id"
      ;;
    notifications/initialized)
      # no response
      ;;
    tools/list)
      printf '{"jsonrpc":"2.0","id":%s,"result":{"tools":[{"name":"mock_tool","description":"A mock tool","inputSchema":{"type":"object","properties":{}}}]}}\n' "$id"
      ;;
    prompts/list)
      printf '{"jsonrpc":"2.0","id":%s,"result":{"prompts":[]}}\n' "$id"
      ;;
    resources/list)
      printf '{"jsonrpc":"2.0","id":%s,"result":{"resources":[]}}\n' "$id"
      ;;
    tools/call)
      printf '{"jsonrpc":"2.0","id":%s,"result":{"content":[{"type":"text","text":"mock result"}]}}\n' "$id"
      ;;
    *)
      printf '{"jsonrpc":"2.0","id":%s,"error":{"code":-32601,"message":"Method not found"}}\n' "$id"
      ;;
  esac
done
