#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

STACK_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
STATE_DIR="$STACK_DIR/.update-state"
BACKUP_DIR="$STACK_DIR/backups"
ENV_FILE="$STACK_DIR/.env"

mkdir -p "$STATE_DIR" "$BACKUP_DIR"
exec 9>"$STATE_DIR/update.lock"
flock -n 9 || exit 0

cd "$STACK_DIR"
docker compose config --quiet

UPDATE_DELAY_DAYS=7
if [[ -f "$ENV_FILE" ]]; then
    configured_delay=$(sed -n "s/^UPDATE_DELAY_DAYS=['\"]*\([0-9][0-9]*\).*/\1/p" "$ENV_FILE" | tail -n1)
    UPDATE_DELAY_DAYS=${configured_delay:-7}
fi
DELAY_SECONDS=$((UPDATE_DELAY_DAYS * 86400))
NOW=$(date +%s)

mapfile -t SERVICES < <(docker compose config --services)
declare -A RUNNING_IMAGE IMAGE_REF CANDIDATE_IMAGE

for service in "${SERVICES[@]}"; do
    container_id=$(docker compose ps -q "$service")
    [[ -n "$container_id" ]] || continue
    RUNNING_IMAGE[$service]=$(docker inspect --format '{{.Image}}' "$container_id")
    IMAGE_REF[$service]=$(docker inspect --format '{{.Config.Image}}' "$container_id")
done

docker compose pull

updates=()
all_mature=true
for service in "${!RUNNING_IMAGE[@]}"; do
    local_image=$(docker image inspect --format '{{.Id}}' "${IMAGE_REF[$service]}" 2>/dev/null || true)
    [[ -n "$local_image" ]] || continue
    state_file="$STATE_DIR/${service}.candidate"

    if [[ "$local_image" == "${RUNNING_IMAGE[$service]}" ]]; then
        rm -f "$state_file"
        continue
    fi

    updates+=("$service")
    CANDIDATE_IMAGE[$service]=$local_image
    first_seen=$NOW
    previous_image=""
    if [[ -f "$state_file" ]]; then
        read -r previous_image first_seen < "$state_file" || true
    fi
    if [[ "$previous_image" != "$local_image" ]]; then
        first_seen=$NOW
        printf '%s %s\n' "$local_image" "$first_seen" > "$state_file"
    fi
    if (( NOW - first_seen < DELAY_SECONDS )); then
        all_mature=false
    fi
done

((${#updates[@]} > 0)) || exit 0
$all_mature || exit 0

timestamp=$(date +%Y%m%d-%H%M%S)
backup="$BACKUP_DIR/media-stack-$timestamp.tar.gz"
rollback_file="$STATE_DIR/rollback-$timestamp.tsv"

for service in "${!RUNNING_IMAGE[@]}"; do
    rollback_tag="media-stack-rollback/${service}:${timestamp}"
    docker image tag "${RUNNING_IMAGE[$service]}" "$rollback_tag"
    printf '%s\t%s\t%s\n' "$service" "${IMAGE_REF[$service]}" "${RUNNING_IMAGE[$service]}" >> "$rollback_file"
done

docker compose stop
tar -czf "$backup" config .env docker-compose.yml important_info.md port.sh update_stack.sh

rollback() {
    trap - ERR
    echo "Update failed; restoring $backup" >&2
    docker compose stop || true
    if [[ -d config ]]; then
        mv config "config.failed-$timestamp"
    fi
    tar -xzf "$backup"
    while IFS=$'\t' read -r service image_ref old_image; do
        docker image tag "$old_image" "$image_ref"
    done < "$rollback_file"
    docker compose up -d --force-recreate
}
trap rollback ERR

docker compose up -d --force-recreate

deadline=$(($(date +%s) + 300))
while :; do
    healthy=true
    for service in "${SERVICES[@]}"; do
        container_id=$(docker compose ps -q "$service")
        if [[ -z "$container_id" ]]; then
            healthy=false
            break
        fi
        status=$(docker inspect --format '{{.State.Status}}' "$container_id")
        health=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$container_id")
        if [[ "$status" != running || "$health" == unhealthy ]]; then
            healthy=false
            break
        fi
        if [[ "$health" != none && "$health" != healthy ]]; then
            healthy=false
            break
        fi
    done
    $healthy && break
    (( $(date +%s) < deadline )) || false
    sleep 10
done

trap - ERR
rm -f "$STATE_DIR"/*.candidate

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

echo "Media Stack updated successfully: ${updates[*]}"
