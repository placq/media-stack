#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

readonly TOOL_VERSION="5.0.0"
STACK_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ENV_FILE="$STACK_DIR/.env"

if [[ -t 1 ]]; then
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; BLUE=''; NC=''
fi
info() { printf '%b[INFO]%b %s\n' "$BLUE" "$NC" "$*"; }
ok() { printf '%b[OK]%b %s\n' "$GREEN" "$NC" "$*"; }
warn() { printf '%b[WARN]%b %s\n' "$YELLOW" "$NC" "$*" >&2; }
fail() { printf '%b[FAIL]%b %s\n' "$RED" "$NC" "$*" >&2; }
die() { fail "$*"; exit 1; }

usage() {
  cat <<'USAGE'
Media Stack management tool

Usage: media-stack COMMAND [ARGUMENT]

Commands:
  status                  Show containers, LAN addresses and timers
  doctor                  Run end-to-end health, VPN, storage and GPU checks
  configure [--quiet]     Idempotently wire the *Arr stack and Bazarr
  repair-ip               Detect a changed LAN IP and recreate port bindings
  backup                  Create a consistent stopped-stack configuration backup
  logs SERVICE            Follow logs for one declared Compose service
  version                 Print installed tool version
  help                    Show this help
USAGE
}

case "${1:-help}" in
  help|-h|--help) (($# <= 1)) || die "help takes no arguments"; usage; exit 0 ;;
  version) (($# == 1)) || die "version takes no arguments"; printf 'media-stack %s\n' "$TOOL_VERSION"; exit 0 ;;
esac

[[ -f "$ENV_FILE" ]] || die "Missing $ENV_FILE. Run the installer first."

read_env() {
  local key=$1 line value
  line=$(awk -v key="$key" 'index($0, key "=") == 1 {print; exit}' "$ENV_FILE")
  [[ -n "$line" ]] || return 0
  value=${line#*=}
  if [[ "$value" == "'"*"'" && ${#value} -ge 2 ]]; then
    value=${value:1:${#value}-2}
  elif [[ "$value" == '"'*'"' && ${#value} -ge 2 ]]; then
    value=${value:1:${#value}-2}
  fi
  printf '%s' "$value"
}

write_env() {
  local key=$1 value=$2 temp line
  [[ "$value" != *"'"* && "$value" != *$'\n'* ]] || die "Unsupported value for $key"
  temp=$(mktemp "$STACK_DIR/.env.XXXXXX")
  line="$key='$value'"
  awk -v key="$key" -v replacement="$line" '
    BEGIN {done=0}
    index($0,key "=")==1 {if(!done) print replacement; done=1; next}
    {print}
    END {if(!done) print replacement}
  ' "$ENV_FILE" >"$temp"
  chmod 0600 "$temp"
  mv -f "$temp" "$ENV_FILE"
}

compose() { (cd "$STACK_DIR" && docker compose "$@"); }

detect_lan_ip() {
  local detected
  detected=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')
  [[ -n "$detected" ]] || detected=$(hostname -I | awk '{print $1}')
  printf '%s' "$detected"
}

has_profile() {
  local profiles
  profiles=$(read_env COMPOSE_PROFILES)
  [[ ",$profiles," == *",$1,"* ]]
}

read_forwarded_port() {
  local json port
  json=$(compose exec -T gluetun wget -qO- -T 5 http://127.0.0.1:8000/v1/portforward 2>/dev/null || true)
  if [[ -n "$json" ]]; then
    port=$(jq -r '.port // (.ports[0] // empty)' <<<"$json" 2>/dev/null || true)
    if [[ "$port" =~ ^[0-9]+$ ]] && ((port >= 1 && port <= 65535)); then
      printf '%s' "$port"
      return 0
    fi
  fi
  port=$(compose exec -T gluetun cat /tmp/gluetun/forwarded_port 2>/dev/null || true)
  port=${port//$'\r'/}; port=${port//$'\n'/}
  [[ "$port" =~ ^[0-9]+$ ]] && ((port >= 1 && port <= 65535)) || return 1
  printf '%s' "$port"
}

command_status() {
  local lan_ip
  lan_ip=$(read_env LAN_IP)
  compose ps
  printf '\nLAN endpoints (%s):\n' "$lan_ip"
  printf '  Jellyfin     http://%s:8096\n' "$lan_ip"
  printf '  Seerr        http://%s:5055\n' "$lan_ip"
  printf '  Transmission http://%s:9091\n' "$lan_ip"
  printf '  Radarr       http://%s:7878\n' "$lan_ip"
  printf '  Sonarr       http://%s:8989\n' "$lan_ip"
  printf '  Prowlarr     http://%s:9696\n' "$lan_ip"
  printf '  Bazarr       http://%s:6767\n' "$lan_ip"
  printf '\nOptional profile: FlareSolverr %s\n' "$(has_profile flaresolverr && printf enabled || printf disabled)"
  printf '\nTimers:\n'
  systemctl list-timers --all media-stack-update.timer media-stack-port-sync.timer --no-pager 2>/dev/null || true
}

CHECK_FAILURES=0
CHECK_WARNINGS=0
check_ok() { ok "$*"; }
check_fail() { fail "$*"; CHECK_FAILURES=$((CHECK_FAILURES+1)); }
check_warn() { warn "$*"; CHECK_WARNINGS=$((CHECK_WARNINGS+1)); }

probe_http() {
  local name=$1 url=$2
  if curl --fail --silent --show-error --max-time 8 "$url" >/dev/null 2>&1; then
    check_ok "$name responds"
  else
    check_fail "$name does not respond at $url"
  fi
}

bazarr_api_key() {
  local file="$STACK_DIR/config/bazarr/config/config.yaml"
  [[ -s "$file" ]] || return 1
  python3 - "$file" <<'PY'
import sys, yaml
try:
    data = yaml.safe_load(open(sys.argv[1], encoding='utf-8')) or {}
    value = ((data.get('auth') or {}).get('apikey') or '').strip()
    if value:
        print(value)
except Exception:
    pass
PY
}

api_key_from_config() {
  local file=$1
  sed -n 's:.*<ApiKey>\([^<]*\)</ApiKey>.*:\1:p' "$file" 2>/dev/null | awk 'NR==1'
}

command_doctor() {
  local configured_ip detected_ip puid pgid storage_test hardlink_source hardlink_target
  local service container_id status health gluetun_id transmission_id network_mode host_ip vpn_ip
  local forwarded_port unit render_gid bazarr_key bazarr_settings
  CHECK_FAILURES=0; CHECK_WARNINGS=0

  [[ $EUID -eq 0 ]] || check_warn "Run as root for complete checks"
  [[ -c /dev/net/tun && -r /dev/net/tun && -w /dev/net/tun ]] && check_ok "/dev/net/tun is usable" || check_fail "/dev/net/tun is not usable"
  docker info >/dev/null 2>&1 && check_ok "Docker daemon is available" || check_fail "Docker daemon is unavailable"
  compose config --quiet >/dev/null 2>&1 && check_ok "Compose configuration is valid" || check_fail "Compose configuration is invalid"

  configured_ip=$(read_env LAN_IP); detected_ip=$(detect_lan_ip)
  if [[ "$configured_ip" == "$detected_ip" ]] && ip -4 addr show | grep -Fq " $configured_ip/"; then
    check_ok "LAN binding matches $configured_ip"
  else
    check_fail "LAN binding is $configured_ip but detected address is $detected_ip; run: media-stack repair-ip"
  fi

  puid=$(read_env PUID); pgid=$(read_env PGID)
  storage_test="$STACK_DIR/data/.doctor-write-test"
  if setpriv --reuid="$puid" --regid="$pgid" --clear-groups touch "$storage_test" 2>/dev/null; then
    rm -f "$storage_test"; check_ok "Media UID:GID can write to data"
  else
    check_fail "Media UID:GID cannot write to $STACK_DIR/data"
  fi
  hardlink_source="$STACK_DIR/data/torrents/.doctor-hardlink-test"
  hardlink_target="$STACK_DIR/data/media/.doctor-hardlink-test"
  if setpriv --reuid="$puid" --regid="$pgid" --clear-groups touch "$hardlink_source" 2>/dev/null &&
     setpriv --reuid="$puid" --regid="$pgid" --clear-groups ln "$hardlink_source" "$hardlink_target" 2>/dev/null; then
    check_ok "Hardlinks work between downloads and media"
  else
    check_warn "Hardlinks do not work; *Arr imports will copy data"
  fi
  rm -f "$hardlink_source" "$hardlink_target"

  while IFS= read -r service; do
    container_id=$(compose ps -q "$service" 2>/dev/null || true)
    if [[ -z "$container_id" ]]; then check_fail "$service has no container"; continue; fi
    status=$(docker inspect --format '{{.State.Status}}' "$container_id" 2>/dev/null || true)
    health=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$container_id" 2>/dev/null || true)
    if [[ "$status" == running && ("$health" == healthy || "$health" == none) ]]; then
      check_ok "$service is running (health: $health)"
    else
      check_fail "$service state is $status (health: $health)"
    fi
  done < <(compose config --services 2>/dev/null || true)

  gluetun_id=$(compose ps -q gluetun 2>/dev/null || true)
  transmission_id=$(compose ps -q transmission 2>/dev/null || true)
  if [[ -n "$gluetun_id" && -n "$transmission_id" ]]; then
    network_mode=$(docker inspect --format '{{.HostConfig.NetworkMode}}' "$transmission_id" 2>/dev/null || true)
    [[ "$network_mode" == "container:$gluetun_id" ]] && check_ok "Transmission shares Gluetun network namespace" || check_fail "Transmission is not isolated behind Gluetun"
  fi

  probe_http Jellyfin http://127.0.0.1:8096/System/Info/Public
  probe_http Seerr http://127.0.0.1:5055/api/v1/settings/public
  probe_http Radarr http://127.0.0.1:7878/ping
  probe_http Sonarr http://127.0.0.1:8989/ping
  probe_http Prowlarr http://127.0.0.1:9696/ping
  probe_http Bazarr http://127.0.0.1:6767/

  if [[ -s "$STACK_DIR/secrets/transmission_user" && -s "$STACK_DIR/secrets/transmission_password" ]] &&
     curl --fail --silent --max-time 8 -u "$(<"$STACK_DIR/secrets/transmission_user"):$(<"$STACK_DIR/secrets/transmission_password")" \
       http://127.0.0.1:9091/transmission/web/ >/dev/null 2>&1; then
    check_ok "Transmission accepts configured credentials"
  else
    check_fail "Transmission credentials/API check failed"
  fi

  host_ip=$(curl --fail --silent --max-time 10 https://api.ipify.org 2>/dev/null || true)
  vpn_ip=$(compose exec -T gluetun wget -qO- -T 10 https://api.ipify.org 2>/dev/null || true)
  host_ip=${host_ip//$'\n'/}; vpn_ip=${vpn_ip//$'\n'/}
  if [[ -n "$host_ip" && -n "$vpn_ip" && "$host_ip" != "$vpn_ip" ]]; then
    check_ok "VPN egress differs from host egress ($vpn_ip vs $host_ip)"
  elif [[ -n "$host_ip" && "$host_ip" == "$vpn_ip" ]]; then
    check_fail "VPN and host public IP are identical ($host_ip)"
  else
    check_warn "Could not compare host and VPN public IPs"
  fi

  forwarded_port=$(read_forwarded_port || true)
  [[ -n "$forwarded_port" ]] && check_ok "ProtonVPN assigned forwarded port $forwarded_port" || check_warn "No valid ProtonVPN forwarded port detected"

  bazarr_key=$(bazarr_api_key || true)
  if [[ -n "$bazarr_key" ]]; then
    bazarr_settings=$(curl -fsS --max-time 8 -H "X-API-KEY: $bazarr_key" http://127.0.0.1:6767/api/system/settings 2>/dev/null || true)
    if jq -e '.general.use_sonarr == true and .general.use_radarr == true and .sonarr.ip == "sonarr" and .radarr.ip == "radarr"' <<<"$bazarr_settings" >/dev/null 2>&1; then
      check_ok "Bazarr is integrated with Sonarr and Radarr"
    else
      check_warn "Bazarr integration is incomplete; run: media-stack configure"
    fi
  else
    check_warn "Bazarr API key could not be read"
  fi

  render_gid=$(read_env RENDER_GID)
  if [[ -n "$render_gid" ]]; then
    if [[ -c /dev/dri/renderD128 ]] && compose exec -T jellyfin test -c /dev/dri/renderD128 >/dev/null 2>&1; then
      check_ok "Jellyfin can see /dev/dri/renderD128"
      if compose exec -T jellyfin /usr/lib/jellyfin-ffmpeg/vainfo --display drm --device /dev/dri/renderD128 >/dev/null 2>&1; then
        check_ok "Jellyfin VA-API driver probe succeeds"
      else
        check_fail "Jellyfin render device exists but vainfo failed"
      fi
    else
      check_fail "GPU support is enabled but Jellyfin cannot access renderD128"
    fi
  else
    check_warn "Hardware transcoding is not enabled in this stack"
  fi

  for unit in media-stack-update.timer media-stack-port-sync.timer; do
    systemctl is-enabled --quiet "$unit" && systemctl is-active --quiet "$unit" && check_ok "$unit is enabled and active" || check_fail "$unit is not enabled and active"
  done

  printf '\nDoctor result: %d failure(s), %d warning(s).\n' "$CHECK_FAILURES" "$CHECK_WARNINGS"
  ((CHECK_FAILURES == 0))
}

wait_http() {
  local url=$1 deadline=$((SECONDS+180))
  until curl --fail --silent --max-time 4 "$url" >/dev/null 2>&1; do
    ((SECONDS < deadline)) || return 1
    sleep 3
  done
}

api_request() {
  local method=$1 url=$2 api_key=$3 payload=${4:-} response
  response=$(mktemp)
  if [[ -n "$payload" ]]; then
    curl --fail --silent --show-error --max-time 20 -X "$method" -H "X-Api-Key: $api_key" -H 'Content-Type: application/json' --data "$payload" "$url" >"$response" || { rm -f "$response"; return 1; }
  else
    curl --fail --silent --show-error --max-time 20 -X "$method" -H "X-Api-Key: $api_key" "$url" >"$response" || { rm -f "$response"; return 1; }
  fi
  cat "$response"; rm -f "$response"
}

ensure_root_folder() {
  local name=$1 base_url=$2 api_key=$3 path=$4 existing payload
  existing=$(api_request GET "$base_url/rootfolder" "$api_key")
  if jq -e --arg path "$path" '.[] | select(.path == $path)' <<<"$existing" >/dev/null; then
    $QUIET || ok "$name root folder already exists: $path"; return
  fi
  payload=$(jq -cn --arg path "$path" '{path:$path}')
  api_request POST "$base_url/rootfolder" "$api_key" "$payload" >/dev/null
  $QUIET || ok "$name root folder created: $path"
}

ensure_transmission_client() {
  local name=$1 base_url=$2 api_key=$3 category=$4 clients existing schema payload id method url
  clients=$(api_request GET "$base_url/downloadclient" "$api_key")
  existing=$(jq -c '[.[] | select(.name == "Media Stack Transmission")][0] // empty' <<<"$clients")
  if [[ -n "$existing" ]]; then
    payload=$existing; id=$(jq -r '.id' <<<"$existing"); method=PUT; url="$base_url/downloadclient/$id"
  else
    schema=$(api_request GET "$base_url/downloadclient/schema" "$api_key")
    payload=$(jq -c '[.[] | select(.implementation == "Transmission")][0] // empty' <<<"$schema")
    [[ -n "$payload" ]] || die "$name did not expose a Transmission client schema"
    method=POST; url="$base_url/downloadclient"
  fi
  payload=$(jq -c \
    --arg username "$(<"$STACK_DIR/secrets/transmission_user")" \
    --arg password "$(<"$STACK_DIR/secrets/transmission_password")" \
    --arg category "$category" '
      .name="Media Stack Transmission" | .enable=true | .priority=1 |
      .fields |= map(
        if .name=="host" then .value="gluetun"
        elif .name=="port" then .value=9091
        elif .name=="useSsl" then .value=false
        elif .name=="urlBase" then .value="/transmission/"
        elif .name=="username" then .value=$username
        elif .name=="password" then .value=$password
        elif (.name=="category" or .name=="movieCategory" or .name=="tvCategory") then .value=$category
        elif .name=="addPaused" then .value=false
        else . end)
    ' <<<"$payload")
  api_request "$method" "$url" "$api_key" "$payload" >/dev/null
  $QUIET || ok "$name is wired to Transmission with category $category"
}

ensure_prowlarr_application() {
  local implementation=$1 target_url=$2 target_key=$3 prowlarr_key=$4 base_url applications existing schema payload id method url
  base_url=http://127.0.0.1:9696/api/v1
  applications=$(api_request GET "$base_url/applications" "$prowlarr_key")
  existing=$(jq -c --arg impl "$implementation" '[.[] | select(.implementation == $impl)][0] // empty' <<<"$applications")
  if [[ -n "$existing" ]]; then
    payload=$existing; id=$(jq -r '.id' <<<"$existing"); method=PUT; url="$base_url/applications/$id"
  else
    schema=$(api_request GET "$base_url/applications/schema" "$prowlarr_key")
    payload=$(jq -c --arg impl "$implementation" '[.[] | select(.implementation == $impl)][0] // empty' <<<"$schema")
    [[ -n "$payload" ]] || die "Prowlarr did not expose the $implementation application schema"
    method=POST; url="$base_url/applications"
  fi
  payload=$(jq -c --arg name "Media Stack $implementation" --arg target "$target_url" --arg key "$target_key" '
    .name=$name | .enable=true | .syncLevel="fullSync" |
    .fields |= map(
      if .name=="prowlarrUrl" then .value="http://prowlarr:9696"
      elif .name=="baseUrl" then .value=$target
      elif .name=="apiKey" then .value=$key
      else . end)
  ' <<<"$payload")
  api_request "$method" "$url" "$prowlarr_key" "$payload" >/dev/null
  $QUIET || ok "Prowlarr is wired to $implementation"
}

ensure_bazarr_integration() {
  local sonarr_key=$1 radarr_key=$2 key settings
  key=$(bazarr_api_key || true)
  [[ -n "$key" ]] || die "Could not read Bazarr API key from config"

  curl --fail --silent --show-error --max-time 30 -X POST \
    -H "X-API-KEY: $key" \
    --data-urlencode 'settings-general-use_sonarr=true' \
    --data-urlencode 'settings-sonarr-ip=sonarr' \
    --data-urlencode 'settings-sonarr-port=8989' \
    --data-urlencode 'settings-sonarr-base_url=/' \
    --data-urlencode 'settings-sonarr-ssl=false' \
    --data-urlencode "settings-sonarr-apikey=$sonarr_key" \
    --data-urlencode 'settings-general-use_radarr=true' \
    --data-urlencode 'settings-radarr-ip=radarr' \
    --data-urlencode 'settings-radarr-port=7878' \
    --data-urlencode 'settings-radarr-base_url=/' \
    --data-urlencode 'settings-radarr-ssl=false' \
    --data-urlencode "settings-radarr-apikey=$radarr_key" \
    http://127.0.0.1:6767/api/system/settings >/dev/null

  settings=$(curl -fsS --max-time 15 -H "X-API-KEY: $key" http://127.0.0.1:6767/api/system/settings)
  jq -e --arg sk "$sonarr_key" --arg rk "$radarr_key" '
    .general.use_sonarr==true and .general.use_radarr==true and
    .sonarr.ip=="sonarr" and .sonarr.port==8989 and .sonarr.apikey==$sk and
    .radarr.ip=="radarr" and .radarr.port==7878 and .radarr.apikey==$rk
  ' <<<"$settings" >/dev/null || die "Bazarr did not persist Sonarr/Radarr integration"
  $QUIET || ok "Bazarr is wired to Sonarr and Radarr"
}

command_configure() {
  QUIET=false
  case "${1:-}" in "") ;; --quiet) QUIET=true ;; *) die "Usage: media-stack configure [--quiet]" ;; esac
  [[ -s "$STACK_DIR/secrets/transmission_user" && -s "$STACK_DIR/secrets/transmission_password" ]] || die "Transmission credentials are missing"
  wait_http http://127.0.0.1:7878/ping || die "Radarr did not become ready"
  wait_http http://127.0.0.1:8989/ping || die "Sonarr did not become ready"
  wait_http http://127.0.0.1:9696/ping || die "Prowlarr did not become ready"
  wait_http http://127.0.0.1:6767/ || die "Bazarr did not become ready"

  local radarr_key sonarr_key prowlarr_key
  radarr_key=$(api_key_from_config "$STACK_DIR/config/radarr/config.xml")
  sonarr_key=$(api_key_from_config "$STACK_DIR/config/sonarr/config.xml")
  prowlarr_key=$(api_key_from_config "$STACK_DIR/config/prowlarr/config.xml")
  [[ -n "$radarr_key" && -n "$sonarr_key" && -n "$prowlarr_key" ]] || die "Could not read one or more *Arr API keys"

  ensure_root_folder Radarr http://127.0.0.1:7878/api/v3 "$radarr_key" /data/media/movies
  ensure_root_folder Sonarr http://127.0.0.1:8989/api/v3 "$sonarr_key" /data/media/tv
  ensure_transmission_client Radarr http://127.0.0.1:7878/api/v3 "$radarr_key" movies
  ensure_transmission_client Sonarr http://127.0.0.1:8989/api/v3 "$sonarr_key" tv
  ensure_prowlarr_application Radarr http://radarr:7878 "$radarr_key" "$prowlarr_key"
  ensure_prowlarr_application Sonarr http://sonarr:8989 "$sonarr_key" "$prowlarr_key"
  ensure_bazarr_integration "$sonarr_key" "$radarr_key"
  $QUIET || ok "Automatic stack wiring is complete"
}

command_repair_ip() {
  local old_ip new_ip escaped_old
  [[ $EUID -eq 0 ]] || die "repair-ip must run as root"
  old_ip=$(read_env LAN_IP); new_ip=$(detect_lan_ip)
  [[ -n "$new_ip" ]] || die "Could not detect current LAN IPv4 address"
  if [[ "$old_ip" == "$new_ip" ]] && ip -4 addr show | grep -Fq " $new_ip/"; then ok "LAN IP is already current: $new_ip"; return; fi
  info "Changing Docker bindings from $old_ip to $new_ip"
  write_env LAN_IP "$new_ip"
  if ! compose up -d --remove-orphans --force-recreate --wait --wait-timeout 420; then
    write_env LAN_IP "$old_ip"; compose up -d --remove-orphans || true; die "Containers failed with $new_ip; restored $old_ip"
  fi
  if [[ -f "$STACK_DIR/important_info.md" ]]; then
    escaped_old=${old_ip//./\\.}; sed -i "s/${escaped_old}/${new_ip}/g" "$STACK_DIR/important_info.md"
  fi
  ok "LAN bindings repaired for $new_ip"
}

validate_offsite_mount() {
  local directory source target current_source current_target
  directory=$(read_env OFFSITE_BACKUP_DIR); [[ -n "$directory" ]] || return 0
  source=$(read_env OFFSITE_BACKUP_SOURCE); target=$(read_env OFFSITE_BACKUP_MOUNTPOINT)
  read -r current_source current_target < <(findmnt -T "$directory" -n -o SOURCE,TARGET --first 2>/dev/null || true)
  [[ "$current_source" == "$source" && "$current_target" == "$target" && -w "$directory" ]] || die "External backup filesystem is unavailable or changed: $directory"
}

command_backup() {
  local state_dir backup_dir timestamp temporary backup offsite stack_stopped item
  local -a items existing_items
  [[ $EUID -eq 0 ]] || die "backup must run as root"
  state_dir="$STACK_DIR/.update-state"; backup_dir="$STACK_DIR/backups"; mkdir -p "$state_dir" "$backup_dir"
  exec 9>"$state_dir/update.lock"; flock -n 9 || die "An update or backup is already running"
  validate_offsite_mount
  timestamp=$(date +%Y%m%d-%H%M%S); temporary="$backup_dir/.media-stack-$timestamp.tar.gz.partial"; backup="$backup_dir/media-stack-$timestamp.tar.gz"
  stack_stopped=false
  restart_stack_on_exit() { local status=$?; trap - EXIT; $stack_stopped && compose up -d --remove-orphans --wait --wait-timeout 420 || true; exit "$status"; }
  trap restart_stack_on_exit EXIT
  compose stop --timeout 60; stack_stopped=true
  items=(config secrets .env compose.yaml compose.openvpn.yaml compose.wireguard.yaml compose.gpu.yaml important_info.md update_stack.sh sync_transmission_port.sh media_stack.sh)
  existing_items=(); for item in "${items[@]}"; do [[ -e "$STACK_DIR/$item" ]] && existing_items+=("$item"); done
  ((${#existing_items[@]} > 0)) || die "No stack configuration files found"
  tar -czf "$temporary" -C "$STACK_DIR" "${existing_items[@]}"; tar -tzf "$temporary" >/dev/null; mv "$temporary" "$backup"
  offsite=$(read_env OFFSITE_BACKUP_DIR); if [[ -n "$offsite" ]]; then validate_offsite_mount; cp -a "$backup" "$offsite/"; fi
  compose up -d --remove-orphans --wait --wait-timeout 420; stack_stopped=false; trap - EXIT
  ok "Consistent backup created: $backup"
}

command_logs() {
  local service=${1:-}; [[ -n "$service" ]] || die "Usage: media-stack logs SERVICE"
  compose config --services | grep -Fxq "$service" || die "Unknown or disabled service: $service"
  compose logs --tail=200 --follow "$service"
}

case "${1:-help}" in
  status) shift; (($#==0)) || die "status takes no arguments"; command_status ;;
  doctor) shift; (($#==0)) || die "doctor takes no arguments"; command_doctor ;;
  configure) shift; (($#<=1)) || die "Usage: media-stack configure [--quiet]"; command_configure "${1:-}" ;;
  repair-ip) shift; (($#==0)) || die "repair-ip takes no arguments"; command_repair_ip ;;
  backup) shift; (($#==0)) || die "backup takes no arguments"; command_backup ;;
  logs) shift; (($#==1)) || die "Usage: media-stack logs SERVICE"; command_logs "$1" ;;
  *) usage >&2; die "Unknown command: $1" ;;
esac
