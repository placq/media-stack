#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

STACK_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
STATE_DIR="$STACK_DIR/.update-state"
BACKUP_DIR="$STACK_DIR/backups"
ENV_FILE="$STACK_DIR/.env"
STABILITY_SECONDS=60
HEALTH_TIMEOUT_SECONDS=300

mkdir -p "$STATE_DIR" "$BACKUP_DIR"
exec 9>"$STATE_DIR/update.lock"
flock -n 9 || exit 0

cd "$STACK_DIR"
docker compose config --quiet

UPDATE_DELAY_DAYS=7
OFFSITE_BACKUP_DIR=""
TR_USER=""
TR_PASS=""
if [[ -f "$ENV_FILE" ]]; then
    # The installer rejects apostrophes/newlines and writes shell-quoted values.
    # shellcheck disable=SC1090
    source "$ENV_FILE"
fi
[[ "$UPDATE_DELAY_DAYS" =~ ^[0-9]+$ ]] || {
    echo "UPDATE_DELAY_DAYS must be a non-negative integer." >&2
    exit 1
}
if [[ -n "$OFFSITE_BACKUP_DIR" && (! -d "$OFFSITE_BACKUP_DIR" || ! -w "$OFFSITE_BACKUP_DIR") ]]; then
    echo "External backup directory is unavailable or not writable: $OFFSITE_BACKUP_DIR" >&2
    exit 1
fi

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
declare -A RUNNING_IMAGE IMAGE_REF CANDIDATE_IMAGE CANDIDATE_MATURE SELECTED

for service in "${SERVICES[@]}"; do
    container_id=$(docker compose ps -q "$service")
    [[ -n "$container_id" ]] || {
        echo "Service $service is not running; start the complete stack before updating." >&2
        exit 1
    }
    RUNNING_IMAGE[$service]=$(docker inspect --format '{{.Image}}' "$container_id")
    IMAGE_REF[$service]=$(docker inspect --format '{{.Config.Image}}' "$container_id")
done

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
        printf '%s %s\n' "$local_image" "$first_seen" > "$state_file"
    fi
    if ((NOW - first_seen >= DELAY_SECONDS)); then
        CANDIDATE_MATURE[$service]=true
    else
        CANDIDATE_MATURE[$service]=false
    fi
done

SELECTED_SERVICES=()
for group in "${UPDATE_GROUPS[@]}"; do
    has_candidate=false
    group_mature=true
    read -r -a group_services <<< "${GROUP_SERVICES[$group]}"
    for service in "${group_services[@]}"; do
        if [[ -n "${CANDIDATE_IMAGE[$service]:-}" ]]; then
            has_candidate=true
            [[ "${CANDIDATE_MATURE[$service]}" == true ]] || group_mature=false
        fi
    done
    if $has_candidate && $group_mature; then
        for service in "${group_services[@]}"; do
            SELECTED[$service]=true
            SELECTED_SERVICES+=("$service")
        done
    fi
done

((${#SELECTED_SERVICES[@]} > 0)) || exit 0

timestamp=$(date +%Y%m%d-%H%M%S)
backup="$BACKUP_DIR/media-stack-$timestamp.tar.gz"
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

    if [[ -n "$OFFSITE_BACKUP_DIR" ]]; then
        mapfile -t offsite_backups < <(find "$OFFSITE_BACKUP_DIR" -maxdepth 1 -type f -name 'media-stack-*.tar.gz' -printf '%T@ %p\n' | sort -nr | cut -d' ' -f2-)
        if ((${#offsite_backups[@]} > 10)); then
            rm -f -- "${offsite_backups[@]:10}"
        fi
    fi
}

rollback() {
    trap - ERR
    set +e
    echo "Update failed; restoring $backup" >&2
    docker compose stop
    if [[ -s "$backup" ]] && tar -tzf "$backup" >/dev/null 2>&1; then
        if [[ -d config ]]; then
            mv config "config.failed-$timestamp"
        fi
        tar -xzf "$backup"
    else
        echo "Backup archive is incomplete; preserving the existing configuration." >&2
    fi
    while IFS=$'\t' read -r _service image_ref old_image; do
        docker image tag "$old_image" "$image_ref"
    done < "$rollback_file"
    docker compose up -d --force-recreate
    for service in "${SELECTED_SERVICES[@]}"; do
        if [[ -n "${CANDIDATE_IMAGE[$service]:-}" ]]; then
            printf '%s %s\n' "${CANDIDATE_IMAGE[$service]}" "$(date +%s)" > "$STATE_DIR/${service}.candidate"
        fi
    done
    prune_artifacts
    exit 1
}
trap rollback ERR

docker compose stop
backup_items=(config .env docker-compose.yml important_info.md update_stack.sh)
[[ -f sync_transmission_port.sh ]] && backup_items+=(sync_transmission_port.sh)
tar -czf "$backup" "${backup_items[@]}"
if [[ -n "$OFFSITE_BACKUP_DIR" ]]; then
    cp -a "$backup" "$OFFSITE_BACKUP_DIR/"
fi

# Pull updates all tags. Restore old tags for groups that are not being deployed now.
for service in "${SERVICES[@]}"; do
    if [[ "${SELECTED[$service]:-false}" != true ]]; then
        docker image tag "${RUNNING_IMAGE[$service]}" "${IMAGE_REF[$service]}"
    fi
done

docker compose start
docker compose up -d --force-recreate "${SELECTED_SERVICES[@]}"

declare -A LAST_RESTARTS
for service in "${SERVICES[@]}"; do
    container_id=$(docker compose ps -q "$service")
    LAST_RESTARTS[$service]=$(docker inspect --format '{{.RestartCount}}' "$container_id")
done

http_probe() {
    case "$1" in
        jellyfin) curl -fsSL --max-time 5 http://127.0.0.1:8096/System/Info/Public >/dev/null ;;
        seerr) curl -fsSL --max-time 5 http://127.0.0.1:5055/api/v1/settings/public >/dev/null ;;
        transmission) curl -fsSL --max-time 5 -u "$TR_USER:$TR_PASS" http://127.0.0.1:9091/transmission/web/ >/dev/null ;;
        radarr) curl -fsSL --max-time 5 http://127.0.0.1:7878/ >/dev/null ;;
        sonarr) curl -fsSL --max-time 5 http://127.0.0.1:8989/ >/dev/null ;;
        prowlarr) curl -fsSL --max-time 5 http://127.0.0.1:9696/ >/dev/null ;;
        bazarr) curl -fsSL --max-time 5 http://127.0.0.1:6767/ >/dev/null ;;
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
    if ! docker exec gluetun wget -qO- http://127.0.0.1:8000/v1/vpn/status | jq -e '.status == "running"' >/dev/null; then
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

trap - ERR
for service in "${SELECTED_SERVICES[@]}"; do
    rm -f "$STATE_DIR/${service}.candidate"
done
rm -f "$rollback_file"
prune_artifacts

echo "Media Stack updated successfully: ${SELECTED_SERVICES[*]}"
