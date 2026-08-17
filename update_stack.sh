#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

STACK_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
STATE_DIR="$STACK_DIR/.update-state"
BACKUP_DIR="$STACK_DIR/backups"
ENV_FILE="$STACK_DIR/.env"
STABILITY_SECONDS=60
HEALTH_TIMEOUT_SECONDS=420

mkdir -p "$STATE_DIR" "$BACKUP_DIR"
exec 9>"$STATE_DIR/update.lock"
flock -n 9 || exit 0
cd "$STACK_DIR"
docker compose config --quiet

read_env() {
  local key=$1 line value
  line=$(awk -v key="$key" 'index($0,key "=")==1 {print; exit}' "$ENV_FILE")
  [[ -n "$line" ]] || return 0
  value=${line#*=}
  if [[ "$value" == "'"*"'" && ${#value} -ge 2 ]]; then value=${value:1:${#value}-2};
  elif [[ "$value" == '"'*'"' && ${#value} -ge 2 ]]; then value=${value:1:${#value}-2}; fi
  printf '%s' "$value"
}

UPDATE_DELAY_DAYS=$(read_env UPDATE_DELAY_DAYS); UPDATE_DELAY_DAYS=${UPDATE_DELAY_DAYS:-7}
OFFSITE_BACKUP_DIR=$(read_env OFFSITE_BACKUP_DIR)
OFFSITE_BACKUP_SOURCE=$(read_env OFFSITE_BACKUP_SOURCE)
OFFSITE_BACKUP_MOUNTPOINT=$(read_env OFFSITE_BACKUP_MOUNTPOINT)
[[ "$UPDATE_DELAY_DAYS" =~ ^[0-9]+$ ]] || { echo "UPDATE_DELAY_DAYS must be a non-negative integer" >&2; exit 1; }

validate_offsite_mount() {
  local current_source current_target
  [[ -n "$OFFSITE_BACKUP_DIR" ]] || return 0
  [[ -d "$OFFSITE_BACKUP_DIR" && -w "$OFFSITE_BACKUP_DIR" ]] || { echo "External backup directory unavailable: $OFFSITE_BACKUP_DIR" >&2; return 1; }
  read -r current_source current_target < <(findmnt -T "$OFFSITE_BACKUP_DIR" -n -o SOURCE,TARGET --first)
  [[ "$current_source" == "$OFFSITE_BACKUP_SOURCE" && "$current_target" == "$OFFSITE_BACKUP_MOUNTPOINT" ]] || {
    echo "External backup mount identity changed" >&2; return 1;
  }
}
validate_offsite_mount

TR_USER=$(<"$STACK_DIR/secrets/transmission_user")
TR_PASS=$(<"$STACK_DIR/secrets/transmission_password")
DELAY_SECONDS=$((UPDATE_DELAY_DAYS*86400)); NOW=$(date +%s)

UPDATE_GROUPS=(vpn flaresolverr prowlarr sonarr radarr bazarr jellyfin seerr)
declare -A GROUP_SERVICES=(
  [vpn]="gluetun transmission"
  [flaresolverr]="flaresolverr"
  [prowlarr]="prowlarr"
  [sonarr]="sonarr"
  [radarr]="radarr"
  [bazarr]="bazarr"
  [jellyfin]="jellyfin"
  [seerr]="seerr"
)

mapfile -t SERVICES < <(docker compose config --services)
declare -A SERVICE_EXISTS RUNNING_IMAGE IMAGE_REF CANDIDATE_IMAGE CANDIDATE_MATURE
for service in "${SERVICES[@]}"; do SERVICE_EXISTS[$service]=true; done
for service in "${SERVICES[@]}"; do
  id=$(docker compose ps -q "$service")
  [[ -n "$id" ]] || { echo "Service $service is not running" >&2; exit 1; }
  RUNNING_IMAGE[$service]=$(docker inspect --format '{{.Image}}' "$id")
  IMAGE_REF[$service]=$(docker inspect --format '{{.Config.Image}}' "$id")
done

restore_running_tags() {
  local service failed=0
  for service in "${SERVICES[@]}"; do docker image tag "${RUNNING_IMAGE[$service]}" "${IMAGE_REF[$service]}" || failed=1; done
  return "$failed"
}
abort_before_deployment() { local status=${1:-1}; trap - ERR INT TERM; set +e; restore_running_tags; exit "$status"; }
trap 'abort_before_deployment $?' ERR
trap 'abort_before_deployment 130' INT TERM

docker compose pull
for service in "${SERVICES[@]}"; do
  local_image=$(docker image inspect --format '{{.Id}}' "${IMAGE_REF[$service]}" 2>/dev/null || true)
  [[ -n "$local_image" ]] || continue
  state_file="$STATE_DIR/${service}.candidate"
  if [[ "$local_image" == "${RUNNING_IMAGE[$service]}" ]]; then rm -f "$state_file"; continue; fi
  CANDIDATE_IMAGE[$service]=$local_image
  first_seen=$NOW; previous_image=""
  if [[ -f "$state_file" ]]; then read -r previous_image first_seen <"$state_file" || true; fi
  if [[ "$previous_image" != "$local_image" || ! "$first_seen" =~ ^[0-9]+$ ]]; then
    first_seen=$NOW; tmp=$(mktemp "$STATE_DIR/.candidate.XXXXXX"); printf '%s %s\n' "$local_image" "$first_seen" >"$tmp"; mv "$tmp" "$state_file"
  fi
  if ((NOW-first_seen >= DELAY_SECONDS)); then CANDIDATE_MATURE[$service]=true; else CANDIDATE_MATURE[$service]=false; fi
done
restore_running_tags
trap - ERR INT TERM

SELECTED_SERVICES=()
for group in "${UPDATE_GROUPS[@]}"; do
  has_candidate=false; group_mature=true; read -r -a group_services <<<"${GROUP_SERVICES[$group]}"
  for service in "${group_services[@]}"; do
    [[ "${SERVICE_EXISTS[$service]:-false}" == true ]] || continue
    if [[ -n "${CANDIDATE_IMAGE[$service]:-}" ]]; then has_candidate=true; [[ "${CANDIDATE_MATURE[$service]}" == true ]] || group_mature=false; fi
  done
  if $has_candidate && $group_mature; then
    for service in "${group_services[@]}"; do [[ "${SERVICE_EXISTS[$service]:-false}" == true ]] && SELECTED_SERVICES+=("$service"); done
  fi
done
((${#SELECTED_SERVICES[@]} > 0)) || exit 0

timestamp=$(date +%Y%m%d-%H%M%S)
backup="$BACKUP_DIR/media-stack-$timestamp.tar.gz"
partial="$BACKUP_DIR/.media-stack-$timestamp.tar.gz.partial"
rollback_file="$STATE_DIR/rollback-$timestamp.tsv"
for service in "${SERVICES[@]}"; do
  docker image tag "${RUNNING_IMAGE[$service]}" "media-stack-rollback/${service}:${timestamp}"
  printf '%s\t%s\t%s\n' "$service" "${IMAGE_REF[$service]}" "${RUNNING_IMAGE[$service]}" >>"$rollback_file"
done

prune_artifacts() {
  local service
  for service in "${SERVICES[@]}"; do
    mapfile -t tags < <(docker images "media-stack-rollback/$service" --format '{{.Repository}}:{{.Tag}}' | sort -r)
    ((${#tags[@]} <= 2)) || docker image rm "${tags[@]:2}" >/dev/null 2>&1 || true
  done
  mapfile -t backups < <(find "$BACKUP_DIR" -maxdepth 1 -type f -name 'media-stack-*.tar.gz' -printf '%T@ %p\n' | sort -nr | cut -d' ' -f2-)
  ((${#backups[@]} <= 5)) || rm -f -- "${backups[@]:5}"
  if [[ -n "$OFFSITE_BACKUP_DIR" ]] && validate_offsite_mount; then
    mapfile -t offsite < <(find "$OFFSITE_BACKUP_DIR" -maxdepth 1 -type f -name 'media-stack-*.tar.gz' -printf '%T@ %p\n' | sort -nr | cut -d' ' -f2-)
    ((${#offsite[@]} <= 10)) || rm -f -- "${offsite[@]:10}"
  fi
}

rollback() {
  local status=${1:-1}; trap - ERR INT TERM; set +e
  echo "Update failed; rolling back" >&2
  docker compose stop --timeout 60
  if [[ -s "$backup" ]] && tar -tzf "$backup" >/dev/null 2>&1; then
    [[ ! -d config ]] || mv config "config.failed-$timestamp"
    tar -xzf "$backup" -C "$STACK_DIR"
  else
    rm -f "$partial"
  fi
  while IFS=$'\t' read -r _ image_ref old_image; do docker image tag "$old_image" "$image_ref"; done <"$rollback_file"
  docker compose up -d --remove-orphans --force-recreate
  for service in "${SELECTED_SERVICES[@]}"; do [[ -z "${CANDIDATE_IMAGE[$service]:-}" ]] || printf '%s %s\n' "${CANDIDATE_IMAGE[$service]}" "$(date +%s)" >"$STATE_DIR/${service}.candidate"; done
  prune_artifacts
  exit "$status"
}
trap rollback ERR
trap 'rollback 130' INT TERM

docker compose stop --timeout 60
items=(config secrets .env compose.yaml compose.openvpn.yaml compose.wireguard.yaml compose.gpu.yaml important_info.md update_stack.sh sync_transmission_port.sh media_stack.sh)
existing=(); for item in "${items[@]}"; do [[ -e "$item" ]] && existing+=("$item"); done
tar -czf "$partial" "${existing[@]}"; tar -tzf "$partial" >/dev/null; mv "$partial" "$backup"
if [[ -n "$OFFSITE_BACKUP_DIR" ]]; then validate_offsite_mount; cp -a "$backup" "$OFFSITE_BACKUP_DIR/"; fi
for service in "${SELECTED_SERVICES[@]}"; do [[ -z "${CANDIDATE_IMAGE[$service]:-}" ]] || docker image tag "${CANDIDATE_IMAGE[$service]}" "${IMAGE_REF[$service]}"; done

docker compose up -d --force-recreate "${SELECTED_SERVICES[@]}"
docker compose start

declare -A LAST_RESTARTS
for service in "${SERVICES[@]}"; do id=$(docker compose ps -q "$service"); LAST_RESTARTS[$service]=$(docker inspect --format '{{.RestartCount}}' "$id"); done

http_probe() {
  case "$1" in
    jellyfin) curl -fsS --max-time 5 http://127.0.0.1:8096/System/Info/Public >/dev/null ;;
    seerr) curl -fsS --max-time 5 http://127.0.0.1:5055/api/v1/settings/public >/dev/null ;;
    transmission) curl -fsS --max-time 5 -u "$TR_USER:$TR_PASS" http://127.0.0.1:9091/transmission/web/ >/dev/null ;;
    radarr) curl -fsS --max-time 5 http://127.0.0.1:7878/ping >/dev/null ;;
    sonarr) curl -fsS --max-time 5 http://127.0.0.1:8989/ping >/dev/null ;;
    prowlarr) curl -fsS --max-time 5 http://127.0.0.1:9696/ping >/dev/null ;;
    bazarr) curl -fsS --max-time 5 http://127.0.0.1:6767/ >/dev/null ;;
    *) true ;;
  esac
}

read_forwarded_port() {
  local json port
  json=$(docker compose exec -T gluetun wget -qO- -T 5 http://127.0.0.1:8000/v1/portforward 2>/dev/null || true)
  port=$(jq -r '.port // (.ports[0] // empty)' <<<"$json" 2>/dev/null || true)
  if [[ "$port" =~ ^[0-9]+$ ]] && ((port>=1 && port<=65535)); then printf '%s' "$port"; return 0; fi
  port=$(docker compose exec -T gluetun cat /tmp/gluetun/forwarded_port 2>/dev/null || true); port=${port//$'\n'/}
  [[ "$port" =~ ^[0-9]+$ ]] && ((port>=1 && port<=65535)) || return 1; printf '%s' "$port"
}

stable_since=0; deadline=$(($(date +%s)+HEALTH_TIMEOUT_SECONDS))
while (($(date +%s)<deadline)); do
  healthy=true
  for service in "${SERVICES[@]}"; do
    id=$(docker compose ps -q "$service"); [[ -n "$id" ]] || { healthy=false; break; }
    status=$(docker inspect --format '{{.State.Status}}' "$id"); health=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$id"); restarts=$(docker inspect --format '{{.RestartCount}}' "$id")
    [[ "$status" == running && ("$health" == none || "$health" == healthy) ]] || { healthy=false; break; }
    if [[ "$restarts" != "${LAST_RESTARTS[$service]}" ]]; then LAST_RESTARTS[$service]=$restarts; healthy=false; fi
    http_probe "$service" || healthy=false
  done
  read_forwarded_port >/dev/null || healthy=false
  if $healthy; then
    ((stable_since>0)) || stable_since=$(date +%s)
    if (($(date +%s)-stable_since >= STABILITY_SECONDS)); then break; fi
  else stable_since=0; fi
  sleep 10
done
((stable_since>0 && $(date +%s)-stable_since >= STABILITY_SECONDS)) || { echo "Updated stack did not remain healthy" >&2; false; }

trap - ERR INT TERM
for service in "${SELECTED_SERVICES[@]}"; do rm -f "$STATE_DIR/${service}.candidate"; done
rm -f "$rollback_file"
prune_artifacts
echo "Media Stack updated successfully: ${SELECTED_SERVICES[*]}"
