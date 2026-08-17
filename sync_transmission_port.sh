#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

STACK_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
STATE_DIR="$STACK_DIR/.update-state"
RPC_URL="http://127.0.0.1:9091/transmission/rpc"

mkdir -p "$STATE_DIR"
exec 9>"$STATE_DIR/port-sync.lock"
flock -n 9 || exit 0

TR_USER_FILE="$STACK_DIR/secrets/transmission_user"
TR_PASS_FILE="$STACK_DIR/secrets/transmission_password"
[[ -s "$TR_USER_FILE" && -s "$TR_PASS_FILE" ]] || {
  echo "Missing Transmission credentials." >&2
  exit 1
}
TR_USER=$(<"$TR_USER_FILE")
TR_PASS=$(<"$TR_PASS_FILE")
cd "$STACK_DIR"

read_forwarded_port() {
  local json port
  json=$(docker compose exec -T gluetun wget -qO- -T 5 http://127.0.0.1:8000/v1/portforward 2>/dev/null || true)
  if [[ -n "$json" ]]; then
    port=$(jq -r '.port // (.ports[0] // empty)' <<<"$json" 2>/dev/null || true)
    if [[ "$port" =~ ^[0-9]+$ ]] && ((port >= 1 && port <= 65535)); then
      printf '%s' "$port"
      return 0
    fi
  fi

  # Compatibility fallback for Gluetun v3. The status file is deprecated in v4.
  port=$(docker compose exec -T gluetun cat /tmp/gluetun/forwarded_port 2>/dev/null || true)
  port=${port//$'\r'/}
  port=${port//$'\n'/}
  [[ "$port" =~ ^[0-9]+$ ]] && ((port >= 1 && port <= 65535)) || return 1
  printf '%s' "$port"
}

forwarded_port=$(read_forwarded_port || true)
if [[ -z "$forwarded_port" ]]; then
  echo "ProtonVPN has not assigned a valid forwarded port yet; the timer will retry."
  exit 0
fi

temp_dir=$(mktemp -d)
trap 'rm -rf -- "$temp_dir"' EXIT
headers="$temp_dir/headers"
response="$temp_dir/response.json"

http_code=$(curl --silent --show-error --max-time 10 \
  -u "$TR_USER:$TR_PASS" -D "$headers" -o /dev/null -X POST \
  -w '%{http_code}' "$RPC_URL")
[[ "$http_code" == 409 || "$http_code" == 200 ]] || {
  echo "Transmission RPC returned HTTP $http_code while requesting a session token." >&2
  exit 1
}

session_id=$(awk -F ':[[:space:]]*' '
  tolower($1) == "x-transmission-session-id" {gsub(/\r/, "", $2); print $2}
' "$headers" | tail -n1)
[[ -n "$session_id" ]] || {
  echo "Transmission did not return an RPC session ID." >&2
  exit 1
}

rpc() {
  local payload=$1
  curl --fail --silent --show-error --max-time 10 \
    -u "$TR_USER:$TR_PASS" \
    -H "X-Transmission-Session-Id: $session_id" \
    -H 'Content-Type: application/json' \
    --data "$payload" "$RPC_URL" >"$response"
  jq -e '.result == "success"' "$response" >/dev/null
}

rpc '{"method":"session-get","arguments":{"fields":["peer-port"]}}'
current_port=$(jq -r '.arguments["peer-port"] // empty' "$response")
if [[ "$current_port" == "$forwarded_port" ]]; then
  echo "Transmission peer port is already synchronized to $forwarded_port."
  exit 0
fi

payload=$(jq -cn --argjson port "$forwarded_port" '{method:"session-set",arguments:{"peer-port":$port,"peer-port-random-on-start":false}}')
rpc "$payload"
rpc '{"method":"session-get","arguments":{"fields":["peer-port"]}}'
jq -e --argjson port "$forwarded_port" '.arguments["peer-port"] == $port' "$response" >/dev/null

echo "Transmission peer port synchronized from ${current_port:-unknown} to $forwarded_port."
