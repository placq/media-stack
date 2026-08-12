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

cd "$STACK_DIR" || exit 1
docker compose config --quiet

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

UPDATE_DELAY_DAYS=$(read_env UPDATE_DELAY_DAYS)
UPDATE_DELAY_DAYS=${UPDATE_DELAY_DAYS:-7}
OFFSITE_BACKUP_DIR=$(read_env OFFSITE_BACKUP_DIR)
OFFSITE_BACKUP_SOURCE=$(read_env OFFSITE_BACKUP_SOURCE)
OFFSITE_BACKUP_MOUNTPOINT=$(read_env OFFSITE_BACKUP_MOUNTPOINT)
[[ "$UPDATE_DELAY_DAYS" =~ ^[0-9]+$ ]] || {
    echo "UPDATE_DELAY_DAYS must be a non-negative integer." >&2
    exit 1
}

validate_offsite_mount() {
    local current_source current_target
    [[ -n "$OFFSITE_BACKUP_DIR" ]] || return 0
    [[ -d "$OFFSITE_BACKUP_DIR" && -w "$OFFSITE_BACKUP_DIR" ]] || {
        echo "External backup directory is unavailable or not writable: $OFFSITE_BACKUP_DIR" >&2
        return 1
    }
    read -r current_source current_target < <(findmnt -T "$OFFSITE_BACKUP_DIR" -n -o SOURCE,TARGET --first)
    [[ "$current_source" == "$OFFSITE_BACKUP_SOURCE" && "$current_target" == "$OFFSITE_BACKUP_MOUNTPOINT" ]] || {
        echo "External backup mount identity changed: expected $OFFSITE_BACKUP_SOURCE on $OFFSITE_BACKUP_MOUNTPOINT." >&2
        return 1
    }
}
validate_offsite_mount

TR_USER_FILE="$STACK_DIR/secrets/transmission_user"
TR_PASS_FILE="$STACK_DIR/secrets/transmission_password"
[[ -s "$TR_USER_FILE" && -s "$TR_PASS_FILE" ]] || {
    echo "Transmission credential files are missing." >&2
    exit 1
}
TR_USER=$(<"$TR_USER_FILE")
TR_PASS=$(<"$TR_PASS_FILE")

DELAY_SECONDS=$((UPDATE_DELAY_DAYS * 86400))
NOW=$(date +%s)

UPDATE_GROUPS=(vpn ingress flaresolverr prowlarr sonarr radarr bazarr jellyfin seerr)
declare -A GROUP_SERVICES=(
    [vpn]="gluetun transmission"
    [ingress]="socket-proxy newt"
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
    container_id=$(docker compose ps -q "$service")
    [[ -n "$container_id" ]] || {
        echo "Service $service is not running; start the complete active stack before updating." >&2
        exit 1
    }
    RUNNING_IMAGE[$service]=$(docker inspect --format '{{.Image}}' "$container_id")
    IMAGE_REF[$service]=$(docker inspect --format '{{.Config.Image}}' "$container_id")
done

restore_running_tags() {
    local service failed=0
    for service in "${SERVICES[@]}"; do
        docker image tag "${RUNNING_IMAGE[$service]}" "${IMAGE_REF[$service]}" || failed=1
    done
    return "$failed"
}

abort_before_deployment() {
    local status=${1:-1}
    trap - ERR INT TERM
    set +e
    restore_running_tags
    echo "Update check was interrupted; image tags were restored to the running versions." >&2
    exit "$status"
}

trap 'abort_before_deployment $?' ERR
trap 'abort_before_deployment 130' INT TERM

# Pulling changes local tag pointers but does not modify running containers.
docker compose pull

for service in "${SERVICES[@]}"; do
    local_image=$(docker image inspect --format '{{.Id}}' "${IMAGE_REF[$service]}" 2>/dev/null || true)
    [[ -n "$local_image" ]] || continue
    state_file="$STATE_DIR/${service}.candidate"

    if [[ "$local_image" == "${RUNNING_IMAGE[$service]}" ]]; then
        rm -f "$state_file"
        continue
    fi

    CANDIDATE_IMAGE[$service]=$local_image
    first_seen=$NOW
    previous_image=""
    if [[ -f "$state_file" ]]; then
        read -r previous_image first_seen < "$state_file" || true
    fi
    if [[ "$previous_image" != "$local_image" || ! "$first_seen" =~ ^[0-9]+$ ]]; then
        first_seen=$NOW
        temp_state=$(mktemp "$STATE_DIR/.candidate.XXXXXX")
        printf '%s %s\n' "$local_image" "$first_seen" > "$temp_state"
        mv "$temp_state" "$state_file"
    fi
    if ((NOW - first_seen >= DELAY_SECONDS)); then
        CANDIDATE_MATURE[$service]=true
    else
        CANDIDATE_MATURE[$service]=false
    fi
done

# A pulled tag must never remain pointed at an immature candidate: an unrelated
# manual `docker compose up` would otherwise bypass the maturation delay.
restore_running_tags
trap - ERR INT TERM

SELECTED_SERVICES=()
for group in "${UPDATE_GROUPS[@]}"; do
    has_candidate=false
    group_mature=true
    read -r -a group_services <<< "${GROUP_SERVICES[$group]}"
    for service in "${group_services[@]}"; do
        [[ "${SERVICE_EXISTS[$service]:-false}" == true ]] || continue
        if [[ -n "${CANDIDATE_IMAGE[$service]:-}" ]]; then
            has_candidate=true
            [[ "${CANDIDATE_MATURE[$service]}" == true ]] || group_mature=false
        fi
    done
    if $has_candidate && $group_mature; then
        for service in "${group_services[@]}"; do
            [[ "${SERVICE_EXISTS[$service]:-false}" == true ]] || continue
            SELECTED_SERVICES+=("$service")
        done
    fi
done

((${#SELECTED_SERVICES[@]} > 0)) || exit 0

timestamp=$(date +%Y%m%d-%H%M%S)
backup="$BACKUP_DIR/media-stack-$timestamp.tar.gz"
partial_backup="$BACKUP_DIR/.media-stack-$timestamp.tar.gz.partial"
rollback_file="$STATE_DIR/rollback-$timestamp.tsv"

for service in "${SERVICES[@]}"; do
    rollback_tag="media-stack-rollback/${service}:${timestamp}"
    docker image tag "${RUNNING_IMAGE[$service]}" "$rollback_tag"
    printf '%s\t%s\t%s\n' "$service" "${IMAGE_REF[$service]}" "${RUNNING_IMAGE[$service]}" >> "$rollback_file"
done

prune_artifacts() {
    local service
    for service in "${SERVICES[@]}"; do
        mapfile -t tags < <(docker images "media-stack-rollback/$service" --format '{{.Repository}}:{{.Tag}}' | sort -r)
        if ((${#tags[@]} > 2)); then
            docker image rm "${tags[@]:2}" >/dev/null 2>&1 || true
        fi
    done

    mapfile -t backups < <(find "$BACKUP_DIR" -maxdepth 1 -type f -name 'media-stack-*.tar.gz' -printf '%T@ %p\n' | sort -nr | cut -d' ' -f2-)
    if ((${#backups[@]} > 5)); then
        rm -f -- "${backups[@]:5}"
    fi

    if [[ -n "$OFFSITE_BACKUP_DIR" ]] && validate_offsite_mount; then
        mapfile -t offsite_backups < <(find "$OFFSITE_BACKUP_DIR" -maxdepth 1 -type f -name 'media-stack-*.tar.gz' -printf '%T@ %p\n' | sort -nr | cut -d' ' -f2-)
        if ((${#offsite_backups[@]} > 10)); then
            rm -f -- "${offsite_backups[@]:10}"
        fi
    fi
}

rollback() {
    local status=${1:-1}
    trap - ERR INT TERM
    set +e
    echo "Update failed; restoring the previous images and configuration." >&2
    docker compose stop --timeout 60
    if [[ -s "$backup" ]] && tar -tzf "$backup" >/dev/null 2>&1; then
        if [[ -d config ]]; then
            mv config "config.failed-$timestamp"
        fi
        tar -xzf "$backup" -C "$STACK_DIR"
    elif [[ -e "$partial_backup" ]]; then
        rm -f "$partial_backup"
        echo "The candidate was not started, so the existing configuration is being preserved." >&2
    else
        echo "No valid backup archive exists; preserving the current configuration." >&2
    fi
    while IFS=$'\t' read -r _service image_ref old_image; do
        docker image tag "$old_image" "$image_ref"
    done < "$rollback_file"
    docker compose up -d --remove-orphans --force-recreate
    for service in "${SELECTED_SERVICES[@]}"; do
        if [[ -n "${CANDIDATE_IMAGE[$service]:-}" ]]; then
            printf '%s %s\n' "${CANDIDATE_IMAGE[$service]}" "$(date +%s)" > "$STATE_DIR/${service}.candidate"
        fi
    done
    prune_artifacts
    exit "$status"
}
trap rollback ERR
trap 'rollback 130' INT TERM

docker compose stop --timeout 60
backup_items=(config secrets .env compose.yaml compose.openvpn.yaml compose.wireguard.yaml compose.gpu.yaml important_info.md update_stack.sh sync_transmission_port.sh media_stack.sh)
existing_backup_items=()
for item in "${backup_items[@]}"; do
    [[ -e "$item" ]] && existing_backup_items+=("$item")
done
tar -czf "$partial_backup" "${existing_backup_items[@]}"
tar -tzf "$partial_backup" >/dev/null
mv "$partial_backup" "$backup"
if [[ -n "$OFFSITE_BACKUP_DIR" ]]; then
    validate_offsite_mount
    cp -a "$backup" "$OFFSITE_BACKUP_DIR/"
fi

# Point only mature, selected references at their captured candidate IDs.
for service in "${SELECTED_SERVICES[@]}"; do
    if [[ -n "${CANDIDATE_IMAGE[$service]:-}" ]]; then
        docker image tag "${CANDIDATE_IMAGE[$service]}" "${IMAGE_REF[$service]}"
    fi
done

docker compose up -d --force-recreate "${SELECTED_SERVICES[@]}"
docker compose start

declare -A LAST_RESTARTS
for service in "${SERVICES[@]}"; do
    container_id=$(docker compose ps -q "$service")
    LAST_RESTARTS[$service]=$(docker inspect --format '{{.RestartCount}}' "$container_id")
done

http_probe() {
    case "$1" in
        jellyfin) curl -fsS --max-time 5 http://127.0.0.1:8096/System/Info/Public >/dev/null ;;
        seerr) curl -fsS --max-time 5 http://127.0.0.1:5055/api/v1/settings/public >/dev/null ;;
        transmission) curl -fsS --max-time 5 -u "$TR_USER:$TR_PASS" http://127.0.0.1:9091/transmission/web/ >/dev/null ;;
        radarr) curl -fsS --max-time 5 http://127.0.0.1:7878/ping >/dev/null ;;
        sonarr) curl -fsS --max-time 5 http://127.0.0.1:8989/ping >/dev/null ;;
        prowlarr) curl -fsS --max-time 5 http://127.0.0.1:9696/ping >/dev/null ;;
        bazarr) curl -fsS --max-time 5 http://127.0.0.1:6767/ >/dev/null ;;
    esac
}

stable_since=0
deadline=$(($(date +%s) + HEALTH_TIMEOUT_SECONDS))
while (($(date +%s) < deadline)); do
    healthy=true
    for service in "${SERVICES[@]}"; do
        container_id=$(docker compose ps -q "$service")
        if [[ -z "$container_id" ]]; then
            healthy=false
            break
        fi
        status=$(docker inspect --format '{{.State.Status}}' "$container_id")
        health=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$container_id")
        restarts=$(docker inspect --format '{{.RestartCount}}' "$container_id")
        if [[ "$status" != running || ("$health" != none && "$health" != healthy) ]]; then
            healthy=false
            break
        fi
        if [[ "$restarts" != "${LAST_RESTARTS[$service]}" ]]; then
            LAST_RESTARTS[$service]=$restarts
            healthy=false
        fi
        if ! http_probe "$service"; then
            healthy=false
        fi
    done

    forwarded_port=$(docker compose exec -T gluetun cat /tmp/gluetun/forwarded_port 2>/dev/null || true)
    forwarded_port=${forwarded_port//$'\n'/}
    if [[ ! "$forwarded_port" =~ ^[0-9]+$ ]] || ((forwarded_port < 1 || forwarded_port > 65535)); then
        healthy=false
    fi

    if $healthy; then
        ((stable_since > 0)) || stable_since=$(date +%s)
        if (($(date +%s) - stable_since >= STABILITY_SECONDS)); then
            break
        fi
    else
        stable_since=0
    fi
    sleep 10
done
((stable_since > 0 && $(date +%s) - stable_since >= STABILITY_SECONDS)) || {
    echo "The updated stack did not remain healthy for ${STABILITY_SECONDS}s." >&2
    false
}

trap - ERR INT TERM
for service in "${SELECTED_SERVICES[@]}"; do
    rm -f "$STATE_DIR/${service}.candidate"
done
rm -f "$rollback_file"
prune_artifacts

echo "Media Stack updated successfully: ${SELECTED_SERVICES[*]}"
