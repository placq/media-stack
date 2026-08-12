#!/usr/bin/env bash

set -Eeuo pipefail

REPOSITORY_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$REPOSITORY_ROOT" || exit 1

SCRIPTS=(
    proxmox_lxc.sh
    install_media.sh
    media_stack.sh
    update_stack.sh
    sync_transmission_port.sh
)
bash -n "${SCRIPTS[@]}"
bash media_stack.sh help >/dev/null
[[ "$(bash media_stack.sh version)" == "media-stack 4.0.0" ]]

temp_dir=$(mktemp -d)
trap 'rm -rf -- "$temp_dir"' EXIT
cp templates/*.yaml "$temp_dir/"
mkdir -p "$temp_dir/secrets"
for secret in transmission_user transmission_password proton_openvpn_user proton_openvpn_password proton_wireguard_private_key; do
    printf 'test-value' > "$temp_dir/secrets/$secret"
done

cat > "$temp_dir/.env" <<'EOF'
PUID='1000'
PGID='1000'
TZ='Europe/Warsaw'
LAN_IP='192.0.2.10'
PUBLIC_DOMAIN='example.com'
RENDER_GID='104'
COMPOSE_PROFILES='pangolin,flaresolverr'
EOF

validate_variant() {
    local vpn gpu output
    local -a files
    vpn=$1
    gpu=${2:-no}
    output="$temp_dir/${vpn}-${gpu}.json"
    files=(-f compose.yaml -f "compose.${vpn}.yaml")
    [[ "$gpu" == yes ]] && files+=(-f compose.gpu.yaml)
    (
        cd "$temp_dir" || exit 1
        docker compose "${files[@]}" config --quiet
        docker compose "${files[@]}" config --format json > "$output"
    )
    jq -e . "$output" >/dev/null
}

validate_variant openvpn yes
validate_variant wireguard no

model="$temp_dir/openvpn-yes.json"
jq -e '
    .services.transmission.network_mode == "service:gluetun" and
    .services.gluetun.cap_add == ["NET_ADMIN"] and
    .services["socket-proxy"].environment.POST == "0" and
    .services["socket-proxy"].read_only == true and
    .services.newt.environment.DOCKER_ENFORCE_NETWORK_VALIDATION == "true" and
    .services.jellyfin.labels["pangolin.public-resources.jellyfin.mode"] == "http" and
    .services.seerr.labels["pangolin.public-resources.seerr.mode"] == "http" and
    .services.newt.healthcheck.test[1] == "test -f /tmp/healthy"
' "$model" >/dev/null

wireguard_model="$temp_dir/wireguard-no.json"
jq -e '
    .services.gluetun.environment.WIREGUARD_PRIVATE_KEY_SECRETFILE == "/run/secrets/proton_wireguard_private_key" and
    (.services.gluetun.environment | has("WIREGUARD_PRIVATE_KEY") | not)
' "$wireguard_model" >/dev/null

jq -e '
    (.services.newt.environment | has("NEWT_ID") | not) and
    (.services.newt.environment | has("NEWT_SECRET") | not)
' "$model" >/dev/null

# Administrative services must never declare a Pangolin public resource.
for service in transmission radarr sonarr prowlarr bazarr flaresolverr; do
    if jq -e --arg service "$service" '
        .services[$service].labels // {} |
        keys[]? |
        startswith("pangolin.public-resources.")
    ' "$model" >/dev/null; then
        echo "$service unexpectedly declares a public Pangolin resource" >&2
        exit 1
    fi
done

# VPN and Transmission credentials must be file-backed, not interpolated values.
jq -e '
    .services.gluetun.environment.OPENVPN_USER_SECRETFILE == "/run/secrets/proton_openvpn_user" and
    .services.gluetun.environment.OPENVPN_PASSWORD_SECRETFILE == "/run/secrets/proton_openvpn_password" and
    (.services.gluetun.environment | has("OPENVPN_USER") | not) and
    (.services.gluetun.environment | has("OPENVPN_PASSWORD") | not) and
    .services.transmission.environment.FILE__PASS == "/run/secrets/transmission_password" and
    (.services.transmission.environment | has("PASS") | not)
' "$model" >/dev/null

# The host provisioner must invoke the LXC installer through pct, never locally.
grep -Fq 'pct exec "$CTID" -- env MEDIA_STACK_PROXMOX_LAUNCH=1 \' proxmox_lxc.sh
grep -Fq 'script --quiet --return --command "bash $INSTALLER_PATH --from-proxmox" /dev/null' proxmox_lxc.sh
grep -Fq 'This installer runs only inside an LXC' install_media.sh
if grep -Eq '^[[:space:]]*(sudo[[:space:]]+)?bash[[:space:]]+"?\$INSTALLER_PATH"?[[:space:]]+--from-proxmox' proxmox_lxc.sh; then
    echo "proxmox_lxc.sh contains a local installer invocation" >&2
    exit 1
fi
if grep -Eq '^[[:space:]]*(sudo[[:space:]]+)?docker([[:space:]]|$)' proxmox_lxc.sh; then
    echo "proxmox_lxc.sh contains a Docker invocation on the Proxmox host" >&2
    exit 1
fi
if grep -Eq '^[[:space:]]*(sudo[[:space:]]+)?(apt|apt-get|systemctl)([[:space:]]|$)' proxmox_lxc.sh; then
    echo "proxmox_lxc.sh contains an OS/service installation command on the Proxmox host" >&2
    exit 1
fi

git diff --check
echo "All static validation checks passed."
