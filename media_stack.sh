#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

readonly TOOL_VERSION="4.0.0"
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
    cat <<'EOF'
Media Stack management tool

Usage: media-stack COMMAND [ARGUMENT]

Commands:
  status                  Show containers, addresses and timers.
  doctor                  Run end-to-end checks, including VPN leak isolation.
  configure [--quiet]     Idempotently wire Radarr/Sonarr/Prowlarr/Transmission.
  repair-ip               Detect a changed LAN IP and recreate port bindings.
  backup                  Create a consistent stopped-stack configuration backup.
  logs SERVICE            Follow logs for one declared Compose service.
  version                 Print the installed tool version.
  help                    Show this help.
EOF
}

# Help and version must also work from a source checkout, before installation
# has created the runtime environment file.
case "${1:-help}" in
    help|-h|--help)
        (($# <= 1)) || die "help takes no arguments."
        usage
        exit 0
        ;;
    version)
        (($# == 1)) || die "version takes no arguments."
        printf 'media-stack %s\n' "$TOOL_VERSION"
        exit 0
        ;;
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
    [[ "$value" != *"'"* && "$value" != *$'\n'* ]] || die "Unsupported value for $key."
    temp=$(mktemp "$STACK_DIR/.env.XXXXXX")
    line="$key='$value'"
    awk -v key="$key" -v replacement="$line" '
        BEGIN { done = 0 }
        index($0, key "=") == 1 {
            if (!done) print replacement
            done = 1
            next
        }
        { print }
        END { if (!done) print replacement }
    ' "$ENV_FILE" > "$temp"
    chmod 0600 "$temp"
    mv -f "$temp" "$ENV_FILE"
}

compose() {
    (cd "$STACK_DIR" && docker compose "$@")
}

detect_lan_ip() {
    local detected
    detected=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i == "src") {print $(i+1); exit}}')
    [[ -n "$detected" ]] || detected=$(hostname -I | awk '{print $1}')
    printf '%s' "$detected"
}

has_profile() {
    local profiles
    profiles=$(read_env COMPOSE_PROFILES)
    [[ ",$profiles," == *",$1,"* ]]
}

command_status() {
    local lan_ip public_domain
    lan_ip=$(read_env LAN_IP)
    public_domain=$(read_env PUBLIC_DOMAIN)
    compose ps
    printf '\nLAN endpoints (%s):\n' "$lan_ip"
    printf '  Jellyfin     http://%s:8096\n' "$lan_ip"
    printf '  Seerr        http://%s:5055\n' "$lan_ip"
    printf '  Transmission http://%s:9091\n' "$lan_ip"
    printf '  Radarr       http://%s:7878\n' "$lan_ip"
    printf '  Sonarr       http://%s:8989\n' "$lan_ip"
    printf '  Prowlarr     http://%s:9696\n' "$lan_ip"
    printf '  Bazarr       http://%s:6767\n' "$lan_ip"
    if has_profile pangolin; then
        printf '\nPublic through Pangolin:\n  https://jellyfin.%s\n  https://seerr.%s\n' "$public_domain" "$public_domain"
    fi
    if [[ "$(read_env ENABLE_TAILSCALE)" == yes ]] && command -v tailscale >/dev/null; then
        printf '\nTailscale IP: %s\n' "$(tailscale ip -4 2>/dev/null | head -n1 || printf 'disconnected')"
    fi
    printf '\nTimers:\n'
    systemctl list-timers --all media-stack-update.timer media-stack-port-sync.timer --no-pager 2>/dev/null || true
}

CHECK_FAILURES=0
CHECK_WARNINGS=0
check_ok() { ok "$*"; }
check_fail() { fail "$*"; CHECK_FAILURES=$((CHECK_FAILURES + 1)); }
check_warn() { warn "$*"; CHECK_WARNINGS=$((CHECK_WARNINGS + 1)); }

probe_http() {
    local name=$1 url=$2
    if curl --fail --silent --show-error --max-time 8 "$url" >/dev/null 2>&1; then
        check_ok "$name responds at $url"
    else
        check_fail "$name does not respond at $url"
    fi
}

command_doctor() {
    local configured_ip detected_ip puid pgid storage_test hardlink_source hardlink_target
    local service container_id status health gluetun_id transmission_id network_mode host_ip vpn_ip
    local forwarded_port offsite_dir offsite_source offsite_mount current_source current_target unit tailscale_ip
    CHECK_FAILURES=0
    CHECK_WARNINGS=0

    [[ $EUID -eq 0 ]] || check_warn "Run as root for complete storage and systemd checks."
    if [[ -c /dev/net/tun && -r /dev/net/tun && -w /dev/net/tun ]]; then
        check_ok "/dev/net/tun is usable"
    else
        check_fail "/dev/net/tun is not usable"
    fi
    if docker info >/dev/null 2>&1; then check_ok "Docker daemon is available"; else check_fail "Docker daemon is unavailable"; fi
    if compose config --quiet >/dev/null 2>&1; then check_ok "Compose configuration is valid"; else check_fail "Compose configuration is invalid"; fi

    configured_ip=$(read_env LAN_IP)
    detected_ip=$(detect_lan_ip)
    if [[ "$configured_ip" == "$detected_ip" ]] && ip -4 addr show | grep -Fq " $configured_ip/"; then
        check_ok "LAN binding matches the current address ($configured_ip)"
    else
        check_fail "LAN binding is $configured_ip but the detected address is $detected_ip; run: media-stack repair-ip"
    fi

    puid=$(read_env PUID)
    pgid=$(read_env PGID)
    storage_test="$STACK_DIR/data/.doctor-write-test"
    if setpriv --reuid="$puid" --regid="$pgid" --clear-groups touch "$storage_test" 2>/dev/null; then
        rm -f "$storage_test"
        check_ok "Media UID:GID can write to the data directory"
    else
        check_fail "Media UID:GID cannot write to $STACK_DIR/data"
    fi
    hardlink_source="$STACK_DIR/data/torrents/.doctor-hardlink-test"
    hardlink_target="$STACK_DIR/data/media/.doctor-hardlink-test"
    if setpriv --reuid="$puid" --regid="$pgid" --clear-groups touch "$hardlink_source" 2>/dev/null &&
        setpriv --reuid="$puid" --regid="$pgid" --clear-groups ln "$hardlink_source" "$hardlink_target" 2>/dev/null; then
        check_ok "Hardlinks work across download and media paths"
    else
        check_warn "Hardlinks do not work; ARR imports will copy data"
    fi
    rm -f "$hardlink_source" "$hardlink_target"

    while IFS= read -r service; do
        container_id=$(compose ps -q "$service" 2>/dev/null || true)
        if [[ -z "$container_id" ]]; then
            check_fail "$service has no container"
            continue
        fi
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
        if [[ "$network_mode" == "container:$gluetun_id" ]]; then
            check_ok "Transmission shares Gluetun's network namespace (kill switch enforced)"
        else
            check_fail "Transmission is not isolated in Gluetun's network namespace"
        fi
    fi

    probe_http Jellyfin http://127.0.0.1:8096/System/Info/Public
    probe_http Seerr http://127.0.0.1:5055/api/v1/settings/public
    probe_http Radarr http://127.0.0.1:7878/ping
    probe_http Sonarr http://127.0.0.1:8989/ping
    probe_http Prowlarr http://127.0.0.1:9696/ping
    probe_http Bazarr http://127.0.0.1:6767/
    if [[ ! -s "$STACK_DIR/secrets/transmission_user" || ! -s "$STACK_DIR/secrets/transmission_password" ]]; then
        check_fail "Transmission credential files are missing"
    elif curl --fail --silent --show-error --max-time 8 \
        -u "$(<"$STACK_DIR/secrets/transmission_user"):$(<"$STACK_DIR/secrets/transmission_password")" \
        http://127.0.0.1:9091/transmission/web/ >/dev/null 2>&1; then
        check_ok "Transmission responds with the configured credentials"
    else
        check_fail "Transmission does not accept the configured credentials"
    fi

    host_ip=$(curl --fail --silent --show-error --max-time 10 https://api.ipify.org 2>/dev/null || true)
    vpn_ip=$(compose exec -T gluetun wget -qO- -T 10 https://api.ipify.org 2>/dev/null || true)
    host_ip=${host_ip//$'\n'/}
    vpn_ip=${vpn_ip//$'\n'/}
    if [[ -n "$host_ip" && -n "$vpn_ip" && "$host_ip" != "$vpn_ip" ]]; then
        check_ok "VPN egress is distinct from host egress ($vpn_ip vs $host_ip)"
    elif [[ -n "$host_ip" && "$host_ip" == "$vpn_ip" ]]; then
        check_fail "VPN and host public IP are identical ($host_ip); stop Transmission and inspect Gluetun"
    else
        check_warn "Could not compare public host and VPN addresses"
    fi

    forwarded_port=$(compose exec -T gluetun cat /tmp/gluetun/forwarded_port 2>/dev/null || true)
    forwarded_port=${forwarded_port//$'\n'/}
    if [[ "$forwarded_port" =~ ^[0-9]+$ ]] && ((forwarded_port > 0 && forwarded_port < 65536)); then
        check_ok "ProtonVPN assigned forwarded port $forwarded_port"
    else
        check_warn "ProtonVPN has not assigned a valid forwarded port"
    fi

    offsite_dir=$(read_env OFFSITE_BACKUP_DIR)
    if [[ -n "$offsite_dir" ]]; then
        offsite_source=$(read_env OFFSITE_BACKUP_SOURCE)
        offsite_mount=$(read_env OFFSITE_BACKUP_MOUNTPOINT)
        current_source=""
        current_target=""
        read -r current_source current_target < <(findmnt -T "$offsite_dir" -n -o SOURCE,TARGET --first 2>/dev/null || true)
        if [[ "$current_source" == "$offsite_source" && "$current_target" == "$offsite_mount" && -w "$offsite_dir" ]]; then
            check_ok "External backup mount identity is unchanged ($offsite_source on $offsite_mount)"
        else
            check_fail "External backup mount is missing or changed; refusing silent fallback to local storage"
        fi
    fi

    for unit in media-stack-update.timer media-stack-port-sync.timer; do
        if systemctl is-enabled --quiet "$unit" && systemctl is-active --quiet "$unit"; then
            check_ok "$unit is enabled and active"
        else
            check_fail "$unit is not enabled and active"
        fi
    done
    if [[ "$(read_env ENABLE_TAILSCALE)" == yes ]]; then
        tailscale_ip=$(tailscale ip -4 2>/dev/null | awk 'NR == 1' || true)
        if [[ -n "$tailscale_ip" ]]; then check_ok "Tailscale is connected"; else check_fail "Tailscale is disconnected"; fi
    fi

    printf '\nDoctor result: %d failure(s), %d warning(s).\n' "$CHECK_FAILURES" "$CHECK_WARNINGS"
    ((CHECK_FAILURES == 0))
}

api_key_from_config() {
    local file=$1
    sed -n 's:.*<ApiKey>\([^<]*\)</ApiKey>.*:\1:p' "$file" 2>/dev/null | awk 'NR == 1' || true
}

wait_http() {
    local url=$1 deadline=$((SECONDS + 120))
    until curl --fail --silent --max-time 4 "$url" >/dev/null 2>&1; do
        ((SECONDS < deadline)) || return 1
        sleep 3
    done
}

api_request() {
    local method=$1 url=$2 api_key=$3 payload=${4:-} response
    response=$(mktemp)
    if [[ -n "$payload" ]]; then
        if ! curl --fail --silent --show-error --max-time 20 -X "$method" \
            -H "X-Api-Key: $api_key" -H 'Content-Type: application/json' \
            --data "$payload" "$url" > "$response"; then
            rm -f "$response"
            return 1
        fi
    else
        if ! curl --fail --silent --show-error --max-time 20 -X "$method" \
            -H "X-Api-Key: $api_key" "$url" > "$response"; then
            rm -f "$response"
            return 1
        fi
    fi
    cat "$response"
    rm -f "$response"
}

ensure_root_folder() {
    local name=$1 base_url=$2 api_key=$3 path=$4 existing payload
    existing=$(api_request GET "$base_url/rootfolder" "$api_key")
    if jq -e --arg path "$path" '.[] | select(.path == $path)' <<< "$existing" >/dev/null; then
        $QUIET || ok "$name root folder already exists: $path"
        return
    fi
    payload=$(jq -cn --arg path "$path" '{path:$path}')
    api_request POST "$base_url/rootfolder" "$api_key" "$payload" >/dev/null
    $QUIET || ok "$name root folder created: $path"
}

ensure_transmission_client() {
    local name=$1 base_url=$2 api_key=$3 category=$4 clients existing schema payload id method url
    clients=$(api_request GET "$base_url/downloadclient" "$api_key")
    existing=$(jq -c '[.[] | select(.name == "Media Stack Transmission")][0] // empty' <<< "$clients")
    if [[ -n "$existing" ]]; then
        payload=$existing
        id=$(jq -r '.id' <<< "$existing")
        method=PUT
        url="$base_url/downloadclient/$id"
    else
        schema=$(api_request GET "$base_url/downloadclient/schema" "$api_key")
        payload=$(jq -c '[.[] | select(.implementation == "Transmission")][0] // empty' <<< "$schema")
        [[ -n "$payload" ]] || die "$name did not expose a Transmission download-client schema."
        method=POST
        url="$base_url/downloadclient"
    fi
    payload=$(jq -c \
        --arg username "$(<"$STACK_DIR/secrets/transmission_user")" \
        --arg password "$(<"$STACK_DIR/secrets/transmission_password")" \
        --arg category "$category" '
        .name = "Media Stack Transmission" |
        .enable = true |
        .priority = 1 |
        .fields |= map(
            if .name == "host" then .value = "gluetun"
            elif .name == "port" then .value = 9091
            elif .name == "useSsl" then .value = false
            elif .name == "urlBase" then .value = "/transmission/"
            elif .name == "username" then .value = $username
            elif .name == "password" then .value = $password
            elif (.name == "category" or .name == "movieCategory" or .name == "tvCategory") then .value = $category
            elif .name == "addPaused" then .value = false
            else . end
        )
    ' <<< "$payload")
    api_request "$method" "$url" "$api_key" "$payload" >/dev/null
    $QUIET || ok "$name is wired to Transmission with category $category"
}

ensure_prowlarr_application() {
    local implementation=$1 target_url=$2 target_key=$3 prowlarr_key=$4 base_url existing applications schema payload id method url
    base_url=http://127.0.0.1:9696/api/v1
    applications=$(api_request GET "$base_url/applications" "$prowlarr_key")
    existing=$(jq -c --arg impl "$implementation" '[.[] | select(.implementation == $impl)][0] // empty' <<< "$applications")
    if [[ -n "$existing" ]]; then
        payload=$existing
        id=$(jq -r '.id' <<< "$existing")
        method=PUT
        url="$base_url/applications/$id"
    else
        schema=$(api_request GET "$base_url/applications/schema" "$prowlarr_key")
        payload=$(jq -c --arg impl "$implementation" '[.[] | select(.implementation == $impl)][0] // empty' <<< "$schema")
        [[ -n "$payload" ]] || die "Prowlarr did not expose the $implementation application schema."
        method=POST
        url="$base_url/applications"
    fi
    payload=$(jq -c --arg name "Media Stack $implementation" --arg target "$target_url" --arg key "$target_key" '
        .name = $name |
        .enable = true |
        .syncLevel = "fullSync" |
        .fields |= map(
            if .name == "prowlarrUrl" then .value = "http://prowlarr:9696"
            elif .name == "baseUrl" then .value = $target
            elif .name == "apiKey" then .value = $key
            else . end
        )
    ' <<< "$payload")
    api_request "$method" "$url" "$prowlarr_key" "$payload" >/dev/null
    $QUIET || ok "Prowlarr is wired to $implementation"
}

command_configure() {
    QUIET=false
    case "${1:-}" in
        "") ;;
        --quiet) QUIET=true ;;
        *) die "Usage: media-stack configure [--quiet]" ;;
    esac
    [[ -s "$STACK_DIR/secrets/transmission_user" && -s "$STACK_DIR/secrets/transmission_password" ]] ||
        die "Transmission credential files are missing."
    wait_http http://127.0.0.1:7878/ping || die "Radarr did not become ready."
    wait_http http://127.0.0.1:8989/ping || die "Sonarr did not become ready."
    wait_http http://127.0.0.1:9696/ping || die "Prowlarr did not become ready."

    radarr_key=$(api_key_from_config "$STACK_DIR/config/radarr/config.xml")
    sonarr_key=$(api_key_from_config "$STACK_DIR/config/sonarr/config.xml")
    prowlarr_key=$(api_key_from_config "$STACK_DIR/config/prowlarr/config.xml")
    [[ -n "$radarr_key" && -n "$sonarr_key" && -n "$prowlarr_key" ]] || die "Could not read one or more ARR API keys."

    ensure_root_folder Radarr http://127.0.0.1:7878/api/v3 "$radarr_key" /data/media/movies
    ensure_root_folder Sonarr http://127.0.0.1:8989/api/v3 "$sonarr_key" /data/media/tv
    ensure_transmission_client Radarr http://127.0.0.1:7878/api/v3 "$radarr_key" movies
    ensure_transmission_client Sonarr http://127.0.0.1:8989/api/v3 "$sonarr_key" tv
    ensure_prowlarr_application Radarr http://radarr:7878 "$radarr_key" "$prowlarr_key"
    ensure_prowlarr_application Sonarr http://sonarr:8989 "$sonarr_key" "$prowlarr_key"
    $QUIET || ok "ARR wiring is complete and idempotent."
}

configure_tailscale_serve() {
    [[ "$(read_env ENABLE_TAILSCALE)" == yes ]] || return 0
    command -v tailscale >/dev/null || return 0
    for port in 5055 6767 7878 8096 8989 9091 9696; do
        tailscale serve --bg --https="$port" "http://127.0.0.1:$port" >/dev/null
    done
}

command_repair_ip() {
    local old_ip new_ip escaped_old
    [[ $EUID -eq 0 ]] || die "repair-ip must run as root."
    old_ip=$(read_env LAN_IP)
    new_ip=$(detect_lan_ip)
    [[ -n "$new_ip" ]] || die "Could not detect the current LAN IPv4 address."
    if [[ "$old_ip" == "$new_ip" ]] && ip -4 addr show | grep -Fq " $new_ip/"; then
        ok "The configured LAN IP is already current: $new_ip"
        configure_tailscale_serve
        return
    fi
    info "Changing Docker bindings from $old_ip to $new_ip."
    write_env LAN_IP "$new_ip"
    if ! compose up -d --remove-orphans --force-recreate --wait --wait-timeout 420; then
        write_env LAN_IP "$old_ip"
        compose up -d --remove-orphans || true
        die "Containers failed with $new_ip; restored $old_ip."
    fi
    configure_tailscale_serve
    if [[ -f "$STACK_DIR/important_info.md" ]]; then
        escaped_old=${old_ip//./\\.}
        sed -i "s/${escaped_old}/${new_ip}/g" "$STACK_DIR/important_info.md"
    fi
    ok "LAN bindings were repaired for $new_ip."
}

validate_offsite_mount() {
    local directory source target current_source current_target
    directory=$(read_env OFFSITE_BACKUP_DIR)
    [[ -n "$directory" ]] || return 0
    source=$(read_env OFFSITE_BACKUP_SOURCE)
    target=$(read_env OFFSITE_BACKUP_MOUNTPOINT)
    current_source=""
    current_target=""
    read -r current_source current_target < <(findmnt -T "$directory" -n -o SOURCE,TARGET --first 2>/dev/null || true)
    [[ "$current_source" == "$source" && "$current_target" == "$target" && -w "$directory" ]] ||
        die "External backup filesystem identity changed or is unavailable: $directory"
}

command_backup() {
    local state_dir backup_dir timestamp temporary backup offsite stack_stopped
    local item
    local -a items existing_items
    [[ $EUID -eq 0 ]] || die "backup must run as root."
    state_dir="$STACK_DIR/.update-state"
    backup_dir="$STACK_DIR/backups"
    mkdir -p "$state_dir" "$backup_dir"
    exec 9>"$state_dir/update.lock"
    flock -n 9 || die "An update or backup is already running."
    validate_offsite_mount
    timestamp=$(date +%Y%m%d-%H%M%S)
    temporary="$backup_dir/.media-stack-$timestamp.tar.gz.partial"
    backup="$backup_dir/media-stack-$timestamp.tar.gz"
    stack_stopped=false
    restart_stack_on_exit() {
        local status=$?
        trap - EXIT
        if $stack_stopped; then
            compose up -d --remove-orphans --wait --wait-timeout 420 || true
        fi
        exit "$status"
    }
    trap restart_stack_on_exit EXIT
    compose stop --timeout 60
    stack_stopped=true
    items=(config secrets .env compose.yaml compose.openvpn.yaml compose.wireguard.yaml compose.gpu.yaml important_info.md update_stack.sh sync_transmission_port.sh media_stack.sh)
    existing_items=()
    for item in "${items[@]}"; do
        [[ -e "$STACK_DIR/$item" ]] && existing_items+=("$item")
    done
    ((${#existing_items[@]} > 0)) || die "No stack configuration files were found to back up."
    tar -czf "$temporary" -C "$STACK_DIR" "${existing_items[@]}"
    tar -tzf "$temporary" >/dev/null
    mv "$temporary" "$backup"
    offsite=$(read_env OFFSITE_BACKUP_DIR)
    if [[ -n "$offsite" ]]; then
        validate_offsite_mount
        cp -a "$backup" "$offsite/"
    fi
    compose up -d --remove-orphans --wait --wait-timeout 420
    stack_stopped=false
    trap - EXIT INT TERM
    ok "Consistent backup created: $backup"
}

command_logs() {
    local service=${1:-}
    [[ -n "$service" ]] || die "Usage: media-stack logs SERVICE"
    if ! compose config --services | grep -Fxq "$service"; then
        die "Unknown or disabled service: $service"
    fi
    compose logs --tail=200 --follow "$service"
}

case "${1:-help}" in
    status) shift; (($# == 0)) || die "status takes no arguments."; command_status ;;
    doctor) shift; (($# == 0)) || die "doctor takes no arguments."; command_doctor ;;
    configure) shift; (($# <= 1)) || die "Usage: media-stack configure [--quiet]"; command_configure "${1:-}" ;;
    repair-ip) shift; (($# == 0)) || die "repair-ip takes no arguments."; command_repair_ip ;;
    backup) shift; (($# == 0)) || die "backup takes no arguments."; command_backup ;;
    logs) shift; (($# == 1)) || die "Usage: media-stack logs SERVICE"; command_logs "$1" ;;
    *) usage >&2; die "Unknown command: $1" ;;
esac
