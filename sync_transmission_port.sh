#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

STACK_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ENV_FILE="$STACK_DIR/.env"
RPC_URL="http://127.0.0.1:9091/transmission/rpc"

[[ -f "$ENV_FILE" ]] || {
    echo "Missing $ENV_FILE" >&2
    exit 1
}
# The installer rejects apostrophes/newlines and writes shell-quoted values.
# shellcheck disable=SC1090
source "$ENV_FILE"
: "${TR_USER:?Missing TR_USER in .env}"
: "${TR_PASS:?Missing TR_PASS in .env}"

forwarded_port=$(docker exec gluetun cat /tmp/gluetun/forwarded_port 2>/dev/null || true)
if [[ ! "$forwarded_port" =~ ^[0-9]+$ ]] || ((forwarded_port < 1 || forwarded_port > 65535)); then
    echo "ProtonVPN has not assigned a valid forwarded port yet; retrying on the next timer run."
    exit 0
fi

temp_dir=$(mktemp -d)
trap 'rm -rf -- "$temp_dir"' EXIT
headers="$temp_dir/headers"
response="$temp_dir/response.json"

curl -sS --max-time 10 \
    -u "$TR_USER:$TR_PASS" \
    -D "$headers" \
    -o /dev/null \
    -X POST "$RPC_URL"

session_id=$(awk -F ':[[:space:]]*' '
    tolower($1) == "x-transmission-session-id" {
        gsub(/\r/, "", $2)
        print $2
    }
' "$headers" | tail -n1)
[[ -n "$session_id" ]] || {
    echo "Transmission did not return an RPC session ID." >&2
    exit 1
}

payload=$(jq -cn --argjson port "$forwarded_port" '{
    method: "session-set",
    arguments: {"peer-port": $port, "peer-port-random-on-start": false}
}')
curl -fsS --max-time 10 \
    -u "$TR_USER:$TR_PASS" \
    -H "X-Transmission-Session-Id: $session_id" \
    -H "Content-Type: application/json" \
    --data "$payload" \
    "$RPC_URL" > "$response"
jq -e '.result == "success"' "$response" >/dev/null

curl -fsS --max-time 10 \
    -u "$TR_USER:$TR_PASS" \
    -H "X-Transmission-Session-Id: $session_id" \
    -H "Content-Type: application/json" \
    --data '{"method":"session-get","arguments":{"fields":["peer-port"]}}' \
    "$RPC_URL" > "$response"
jq -e --argjson port "$forwarded_port" '.result == "success" and .arguments["peer-port"] == $port' "$response" >/dev/null

echo "Transmission peer port synchronized to $forwarded_port."
