#!/usr/bin/env bash
set -Eeuo pipefail

REPOSITORY_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$REPOSITORY_ROOT"

SCRIPTS=(
  proxmox_lxc.sh
  install_media.sh
  media_stack.sh
  update_stack.sh
  sync_transmission_port.sh
)

bash -n "${SCRIPTS[@]}"
bash media_stack.sh help >/dev/null
[[ "$(bash media_stack.sh version)" == "media-stack 5.0.0" ]]

# Infrastructure access belongs outside this repository. Keep the media stack
# focused by allowing only the expected application services.
EXPECTED_SERVICES='bazarr flaresolverr gluetun jellyfin prowlarr radarr seerr sonarr transmission'

TEMP_DIR=$(mktemp -d)
trap 'rm -rf -- "$TEMP_DIR"' EXIT
cp templates/*.yaml "$TEMP_DIR/"
mkdir -p "$TEMP_DIR/secrets"
for secret in transmission_user transmission_password proton_openvpn_user proton_openvpn_password proton_wireguard_private_key; do
  printf 'test-value' >"$TEMP_DIR/secrets/$secret"
done

cat >"$TEMP_DIR/.env" <<'ENV'
PUID='1000'
PGID='1000'
TZ='Europe/Warsaw'
LAN_IP='192.0.2.10'
RENDER_GID='104'
COMPOSE_PROFILES='flaresolverr'
ENV

validate_variant() {
  local vpn=$1 gpu=${2:-no} output
  local -a files=(-f compose.yaml -f "compose.${vpn}.yaml")
  [[ "$gpu" == yes ]] && files+=(-f compose.gpu.yaml)
  output="$TEMP_DIR/${vpn}-${gpu}.json"
  (
    cd "$TEMP_DIR"
    docker compose "${files[@]}" config --quiet
    docker compose "${files[@]}" config --format json >"$output"
  )
  jq -e . "$output" >/dev/null
}

validate_variant wireguard yes
validate_variant openvpn no

WG_MODEL="$TEMP_DIR/wireguard-yes.json"
OVPN_MODEL="$TEMP_DIR/openvpn-no.json"

# Exact service inventory prevents accidental infrastructure creep.
ACTUAL_SERVICES=$(jq -r '.services | keys[]' "$WG_MODEL" | sort | xargs)
[[ "$ACTUAL_SERVICES" == "$EXPECTED_SERVICES" ]]

jq -e '
  .services.transmission.network_mode == "service:gluetun" and
  .services.gluetun.cap_add == ["NET_ADMIN"] and
  .services.gluetun.environment.VPN_SERVICE_PROVIDER == "protonvpn" and
  .services.gluetun.environment.VPN_PORT_FORWARDING == "on" and
  .services.gluetun.environment.HTTP_CONTROL_SERVER_AUTH_CONFIG_FILEPATH == "/gluetun/auth/config.toml" and
  .services.jellyfin.devices[0].source == "/dev/dri/renderD128" and
  .services.jellyfin.devices[0].target == "/dev/dri/renderD128"
' "$WG_MODEL" >/dev/null

# Secrets must be file-backed rather than interpolated plaintext values.
jq -e '
  .services.gluetun.environment.WIREGUARD_PRIVATE_KEY_SECRETFILE == "/run/secrets/proton_wireguard_private_key" and
  (.services.gluetun.environment | has("WIREGUARD_PRIVATE_KEY") | not) and
  .services.transmission.environment.FILE__USER == "/run/secrets/transmission_user" and
  .services.transmission.environment.FILE__PASS == "/run/secrets/transmission_password" and
  (.services.transmission.environment | has("USER") | not) and
  (.services.transmission.environment | has("PASS") | not)
' "$WG_MODEL" >/dev/null

jq -e '
  .services.gluetun.environment.OPENVPN_USER_SECRETFILE == "/run/secrets/proton_openvpn_user" and
  .services.gluetun.environment.OPENVPN_PASSWORD_SECRETFILE == "/run/secrets/proton_openvpn_password" and
  (.services.gluetun.environment | has("OPENVPN_USER") | not) and
  (.services.gluetun.environment | has("OPENVPN_PASSWORD") | not)
' "$OVPN_MODEL" >/dev/null

# No application should declare public-ingress metadata; exposure is outside this project.
if jq -e '[.services[] | .labels // {} | length] | any(. > 0)' "$WG_MODEL" >/dev/null; then
  echo "Unexpected service labels found in media Compose" >&2
  exit 1
fi

# Installer defaults and automation contracts.
grep -Fq 'CURRENT_VPN_TYPE=wireguard' install_media.sh
grep -Fq 'prompt ROOT_DISK_GB "Root filesystem size in GiB" 64' proxmox_lxc.sh
# The process-wide umask is intentionally strict, but pct create needs the
# normal Proxmox directory permissions for unprivileged rootfs extraction.
grep -Fq 'umask 022' proxmox_lxc.sh
grep -Fq '    pct create "$CTID" "$TEMPLATE_REF" \\' proxmox_lxc.sh
grep -Fq 'settings-general-use_sonarr=true' media_stack.sh
grep -Fq 'settings-general-use_radarr=true' media_stack.sh
grep -Fq 'settings-sonarr-ip=sonarr' media_stack.sh
grep -Fq 'settings-radarr-ip=radarr' media_stack.sh
grep -Fq '/v1/portforward' sync_transmission_port.sh
grep -Fq '/tmp/gluetun/forwarded_port' sync_transmission_port.sh
grep -Fq '/usr/lib/jellyfin-ffmpeg/vainfo --display drm --device /dev/dri/renderD128' media_stack.sh

# Host provisioner must install applications only through pct inside the LXC.
grep -Fq 'pct exec "$CTID" -- env MEDIA_STACK_PROXMOX_LAUNCH=1 \' proxmox_lxc.sh
grep -Fq 'script --quiet --return --command "bash $INSTALLER_PATH --from-proxmox" /dev/null' proxmox_lxc.sh
if grep -Eq '^[[:space:]]*(sudo[[:space:]]+)?docker([[:space:]]|$)' proxmox_lxc.sh; then
  echo "Host provisioner contains a Docker invocation" >&2
  exit 1
fi
# Do not match systemctl text embedded in commands deliberately executed through
# `pct exec` inside the guest. We only prohibit direct host package installation.
if grep -Eq '^[[:space:]]*(sudo[[:space:]]+)?(apt|apt-get)([[:space:]]|$)' proxmox_lxc.sh; then
  echo "Host provisioner contains a host package installation command" >&2
  exit 1
fi

# Common files should not accidentally grow executable syntax errors or whitespace damage.
git diff --check

echo "All static validation checks passed."
