#!/usr/bin/env bash
# DMS host agent installer.
#
# Source of truth lives in the DMS-Host-Controller repo at installer/install.sh and is
# published to the public installer repo (see installer/README.md). Customers run the
# published copy:
#
#   curl -fsSL https://raw.githubusercontent.com/DreamMtn/DMS-Server-Agent/main/install.sh \
#     | sudo bash -s -- --url https://control.example.com --token <enrollment token> \
#         --release-key /tmp/release_key.pub.pem --version <version> --sha256 <digest>
#
#   The host's enrollment dialog in the control plane prints this with every value filled in.
#
# What it does, in order:
#   1. installs prerequisites (docker, restic, python venv, git; zfsutils unless --no-zfs)
#   2. lays out /opt/dms-agent/versions/<version> and points "current" at it
#   3. writes /etc/dms-agent/config.json, including the release public key
#   4. enrolls with the control plane using the one-time token
#   5. installs and starts the systemd unit
#   (optional) installs cloudflared as an outbound-only tunnel when --tunnel-credentials-file is given
#   (optional) sets up the ZFS pool, asking which disk, when --setup-zfs is given
#
# Re-running it is safe: an existing config keeps its credentials and host-side switches.
set -euo pipefail

INSTALL_ROOT=/opt/dms-agent
CONFIG_DIR=/etc/dms-agent
CONFIG_FILE="${CONFIG_DIR}/config.json"
SERVICE_FILE=/etc/systemd/system/dms-agent.service
AGENT_VERSION="${DMS_AGENT_VERSION:-}"
ARTIFACT_SHA256=""
RELEASE_BASE="${DMS_RELEASE_BASE:-https://github.com/DreamMtn/DMS-Server-Agent/releases/download}"

CONTROL_URL=""
ENROLL_TOKEN=""
ZFS_PARENT="tank/dms"
WITH_ZFS=1
SETUP_ZFS=0
ZFS_PARENT_GIVEN=0
# Only the tests set this: a folder standing in for /dev, /sys, /proc and /etc in the ZFS setup.
ZFS_TEST_ROOT="${DMS_ZFS_TEST_ROOT:-}"
ALLOW_DESTRUCTIVE=0
SKIP_ENROLL=0
WITH_CROWDSEC=1
RELEASE_KEY_FILE=""
TUNNEL_CREDENTIALS_FILE=""
TUNNEL_ID=""
TUNNEL_ACTION=""
TUNNEL_DIR=/etc/dms-tunnel
TUNNEL_METRICS_PORT=20241
TUNNEL_CREDENTIALS="${TUNNEL_DIR}/credentials.json"
TUNNEL_CONFIG="${TUNNEL_DIR}/tunnel.yml"
TUNNEL_SERVICE_FILE=/etc/systemd/system/dms-tunnel.service

die() { echo "error: $*" >&2; exit 1; }
info() { echo "==> $*"; }

usage() {
  cat <<'USAGE'
Usage: install.sh --url <control plane URL> --token <enrollment token> [options]

Required:
  --url URL              Control plane base URL, e.g. https://control.example.com
  --token TOKEN          One-time enrollment token from the host record in Odoo

Options:
  --zfs-parent DATASET   ZFS parent dataset for environments (default: tank/dms)
  --setup-zfs            Create the ZFS pool as part of this install, asking which disk to
                         use. Without --url it does only that, on a server already installed.
                         Safe to repeat: a server that has the pool is left as it is.
  --no-zfs               Host has no ZFS pool. Production environments will refuse to
                         provision, because there would be no snapshot to roll back to.
  --allow-destructive    Permit rollback / restore / prune jobs on this host.
                         Enable on stage hosts; leave off on customer production boxes.
  --release-key FILE     PEM file with the agent release public key. Without it this host
                         cannot be upgraded remotely.
  --version VERSION      Agent version to install. The enrollment dialog fills this in
                         with the release the control plane considers current.
  --sha256 DIGEST        Expected SHA-256 of the agent archive, from the control plane.
                         The install stops if the download does not match.
  --skip-enroll          Install and configure, but do not contact the control plane.
  --no-crowdsec          Do not install CrowdSec (intrusion detection + firewall bouncer).
                         It is installed in detect-only mode; the control plane applies
                         the rules and the mode chosen for this server.
  --tunnel-credentials-file FILE
                         Credentials of a Cloudflare Tunnel made with
                         scripts/create_tunnel.py. Installs cloudflared as the dms-tunnel
                         service, with its routing rules in a file on this host. A new host
                         takes its traffic through the tunnel from the start. The file is
                         copied to a root-only location; delete FILE afterwards.

Moving a host that is already running (none of these need --url, --token or --version):
  --tunnel-only --tunnel-credentials-file FILE
                         Install the tunnel service only. Traffic does not move yet.
  --tunnel-cutover       Send this host's web traffic through the tunnel: nginx closes its
                         public ports, and the control plane moves the DNS records.
  --tunnel-revert        Undo --tunnel-cutover: public ports and DNS records come back.
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --url) CONTROL_URL="${2:?--url needs a value}"; shift 2 ;;
    --token) ENROLL_TOKEN="${2:?--token needs a value}"; shift 2 ;;
    --zfs-parent) ZFS_PARENT="${2:?--zfs-parent needs a value}"; ZFS_PARENT_GIVEN=1; shift 2 ;;
    --setup-zfs) SETUP_ZFS=1; shift ;;
    --no-zfs) WITH_ZFS=0; shift ;;
    --allow-destructive) ALLOW_DESTRUCTIVE=1; shift ;;
    --release-key) RELEASE_KEY_FILE="${2:?--release-key needs a value}"; shift 2 ;;
    --version) AGENT_VERSION="${2:?--version needs a value}"; shift 2 ;;
    --sha256) ARTIFACT_SHA256="${2:?--sha256 needs a value}"; shift 2 ;;
    --skip-enroll) SKIP_ENROLL=1; shift ;;
    --no-crowdsec) WITH_CROWDSEC=0; shift ;;
    --tunnel-credentials-file) TUNNEL_CREDENTIALS_FILE="${2:?--tunnel-credentials-file needs a value}"; shift 2 ;;
    --tunnel-only) TUNNEL_ACTION=install; shift ;;
    --tunnel-cutover) TUNNEL_ACTION=cutover; shift ;;
    --tunnel-revert) TUNNEL_ACTION=revert; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown option $1" ;;
  esac
done

[ "$(id -u)" -eq 0 ] || die "run this as root (sudo)."

# ---------------------------------------------------------------- tunnel
# Read the credentials once, before anything changes, so a bad file stops the install here.
read_tunnel_credentials() {
  [ -f "$TUNNEL_CREDENTIALS_FILE" ] || die "tunnel credentials file not found: $TUNNEL_CREDENTIALS_FILE"
  # cert.pem is what `cloudflared tunnel login` leaves behind. It controls the whole Cloudflare
  # account, so it must never reach a customer server.
  if grep -q 'BEGIN ' "$TUNNEL_CREDENTIALS_FILE"; then
    die "$TUNNEL_CREDENTIALS_FILE looks like an account certificate. Use the tunnel's credentials file."
  fi
  grep -q '"AccountTag"' "$TUNNEL_CREDENTIALS_FILE" && grep -q '"TunnelSecret"' "$TUNNEL_CREDENTIALS_FILE" \
    || die "$TUNNEL_CREDENTIALS_FILE is not a tunnel credentials file"
  TUNNEL_ID="$(sed -n 's/.*"TunnelID"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$TUNNEL_CREDENTIALS_FILE")"
  [[ "$TUNNEL_ID" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] \
    || die "$TUNNEL_CREDENTIALS_FILE has no valid TunnelID"
}

# Host-side, like allow_destructive: the control plane reads these and cannot set them.
# Second argument: 1 or 0 to switch traffic, empty to leave the switch alone.
write_tunnel_settings() {
  python3 - "$CONFIG_FILE" "$1" "$2" <<'PYEOF'
import json, os, sys

path, tunnel_id, enabled = sys.argv[1:4]
with open(path) as handle:
    config = json.load(handle)
if tunnel_id:
    config['tunnel_id'] = tunnel_id
if enabled:
    config['tunnel_enabled'] = enabled == '1'
fd = os.open(path + '.tmp', os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, 'w') as handle:
    json.dump(config, handle, indent=2)
os.replace(path + '.tmp', path)
PYEOF
}

tunnel_connected() {
  curl -fsS -m 3 -o /dev/null "http://127.0.0.1:${TUNNEL_METRICS_PORT}/ready" 2>/dev/null
}

install_tunnel() {
  # Cloudflare's signed package repository, added explicitly like CrowdSec's.
  info "Installing cloudflared (outbound-only tunnel)"
  install -d -m 755 /usr/share/keyrings
  curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg -o /usr/share/keyrings/cloudflare-main.gpg
  chmod 644 /usr/share/keyrings/cloudflare-main.gpg
  printf '%s\n' 'Types: deb' 'URIs: https://pkg.cloudflare.com/cloudflared' 'Suites: any' \
    'Components: main' 'Signed-By: /usr/share/keyrings/cloudflare-main.gpg' \
    > /etc/apt/sources.list.d/cloudflared.sources
  apt-get update -qq
  apt-get install -y -qq cloudflared unattended-upgrades

  # unattended-upgrades only follows the distribution unless told otherwise.
  printf 'Unattended-Upgrade::Origins-Pattern { "origin=cloudflared"; };\n' \
    > /etc/apt/apt.conf.d/52dms-cloudflared

  # Its own user and directory: /etc/dms-agent holds the agent token and stays root-only. The
  # service can read these files and cannot change them, so it cannot rewrite its own rules.
  id dms-tunnel >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin dms-tunnel
  install -d -m 750 -o root -g dms-tunnel "$TUNNEL_DIR"
  install -m 640 -o root -g dms-tunnel "$TUNNEL_CREDENTIALS_FILE" "${TUNNEL_CREDENTIALS}.tmp"
  mv -f "${TUNNEL_CREDENTIALS}.tmp" "$TUNNEL_CREDENTIALS"

  # The routing rules live here, not in the Cloudflare account, so nobody with access to the
  # account can point this host's tunnel at anything else. Everything goes to nginx. HTTP is
  # right: it stays on loopback, and cloudflared has already ended the encrypted connection.
  cat > "${TUNNEL_CONFIG}.tmp" <<YAML
tunnel: ${TUNNEL_ID}
credentials-file: ${TUNNEL_CREDENTIALS}
ingress:
  - service: http://127.0.0.1:80
YAML
  chown root:dms-tunnel "${TUNNEL_CONFIG}.tmp"
  chmod 640 "${TUNNEL_CONFIG}.tmp"
  mv -f "${TUNNEL_CONFIG}.tmp" "$TUNNEL_CONFIG"

  # A private network route added in the Cloudflare account would bypass the rules above, so
  # the service cannot reach private addresses at all. DNS servers on the LAN are the exception.
  local dns_allow
  dns_allow="$(awk '$1 == "nameserver" && $2 ~ /^[0-9a-fA-F:.]+$/ { printf "%s ", $2 }' /etc/resolv.conf)"

  cat > "$TUNNEL_SERVICE_FILE" <<UNIT
[Unit]
Description=DMS tunnel (cloudflared, outbound-only)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
# Updates come from apt, so the binary does not replace itself.
# /ready on the metrics port answers 200 only while connected to Cloudflare. The service can
# stay "active" for ever with a rejected credential, so nothing else proves it works.
ExecStart=/usr/bin/cloudflared --no-autoupdate --metrics 127.0.0.1:${TUNNEL_METRICS_PORT} --config ${TUNNEL_CONFIG} tunnel run
Restart=on-failure
RestartSec=5
User=dms-tunnel
Group=dms-tunnel
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
CapabilityBoundingSet=
IPAddressDeny=10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 169.254.0.0/16 100.64.0.0/10 fc00::/7 fe80::/10
IPAddressAllow=${dns_allow}

[Install]
WantedBy=multi-user.target
UNIT

  # An apt update replaces the binary but leaves the old one running.
  cat > /etc/systemd/system/dms-tunnel-update.path <<'UNIT'
[Unit]
Description=Restart the DMS tunnel when cloudflared is updated

[Path]
PathChanged=/usr/bin/cloudflared

[Install]
WantedBy=multi-user.target
UNIT
  cat > /etc/systemd/system/dms-tunnel-update.service <<'UNIT'
[Unit]
Description=Restart the DMS tunnel after a cloudflared update

[Service]
Type=oneshot
ExecStart=/usr/bin/systemctl try-restart dms-tunnel
UNIT

  systemctl daemon-reload
  systemctl enable --now dms-tunnel-update.path >/dev/null 2>&1
  systemctl enable dms-tunnel >/dev/null 2>&1
  systemctl restart dms-tunnel
  for _ in $(seq 1 20); do
    if tunnel_connected; then
      info "dms-tunnel is connected to Cloudflare (tunnel ${TUNNEL_ID})."
      echo "note: delete ${TUNNEL_CREDENTIALS_FILE} now; the credentials are kept in ${TUNNEL_CREDENTIALS}." >&2
      return 0
    fi
    sleep 3
  done
  echo "warning: dms-tunnel did not connect to Cloudflare within a minute. Recent log:" >&2
  journalctl -u dms-tunnel -n 20 --no-pager >&2 || true
  return 1
}

agent_python() {
  "${INSTALL_ROOT}/current/venv/bin/python" -m dms_agent --config "$CONFIG_FILE" "$@"
}

# Apply the switch to nginx now, and restart the agent so it reports it. The control plane then
# moves the DNS records and rewrites the sites.
switch_tunnel() {
  write_tunnel_settings "" "$1"
  if ! agent_python nginx-sync; then
    write_tunnel_settings "" "$((1 - $1))"
    agent_python nginx-sync || true
    die "nginx could not be switched, so nothing changed. The agent must be 0.16.0 or later."
  fi
  systemctl restart dms-agent
}

# ---------------------------------------------------------------- ZFS pool
# Guided, because creating a pool erases a disk and which disk is right differs on every
# server. The rules that keep it from the wrong disk: a server that has the pool is never
# changed, only whole empty disks are offered, nothing is chosen for you, a typed confirmation
# names what is erased, and `zpool create` is never forced, so ZFS's own check still applies.
# Runs in a subshell under `||`, where set -e does nothing: every step checks for itself.

# One line per disk, tab separated: ok|no, name, size, model, stable path or the refusal.
zfs_disks() {
  local json
  json="$(lsblk -J -b -o NAME,TYPE,SIZE,MODEL,FSTYPE,MOUNTPOINT,RO,RM)" || die "could not list the disks (lsblk)."
  python3 - "$json" "$ZFS_TEST_ROOT" <<'PYEOF'
import json
import os
import subprocess
import sys

root = sys.argv[2]
ZERO_CHECK_BYTES = 1 << 20


def stable_path(name):
    folder = root + '/dev/disk/by-id'
    try:
        entries = sorted(os.listdir(folder))
    except OSError:
        return ''
    found = [entry for entry in entries if '-part' not in entry
             and os.path.basename(os.path.realpath(os.path.join(folder, entry))) == name]
    found.sort(key=lambda entry: entry.startswith('wwn-'))
    return '/dev/disk/by-id/' + found[0] if found else ''


def has_holders(name):
    return bool(os.listdir(f'{root}/sys/block/{name}/holders'))


def starts_with_zeros(name):
    with open(f'{root}/dev/{name}', 'rb') as disk:
        block = disk.read(ZERO_CHECK_BYTES)
    return bool(block) and block.count(0) == len(block)


def refusal(disk):
    """Why this disk is not offered, or '' if it looks new. A check that cannot run refuses."""
    name = disk['name']
    if disk.get('fstype') == 'zfs_member':
        return 'holds a ZFS pool; to reuse it, run: zpool import'
    if disk.get('ro') in (True, 1, '1'):
        return 'read-only'
    if disk.get('rm') in (True, 1, '1'):
        return 'removable'
    if disk.get('children'):
        return 'has partitions or volumes'
    if disk.get('fstype'):
        return f'holds a filesystem ({disk["fstype"]})'
    if disk.get('mountpoint'):
        return f'mounted at {disk["mountpoint"]}'
    try:
        if has_holders(name):
            return 'in use by another device (LVM, RAID or similar)'
        probe = subprocess.run(['blkid', '-p', f'/dev/{name}'], stdin=subprocess.DEVNULL,
                               stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        if probe.returncode == 0:
            return 'holds a filesystem or partition table: ' + probe.stdout.strip()
        if probe.returncode != 2:     # 2 is how blkid says it found nothing
            return 'could not be checked (blkid)'
        if not starts_with_zeros(name):
            return 'not blank: the start of the disk has data on it'
    except OSError as exc:
        return f'could not be checked ({exc.strerror})'
    if not stable_path(name):
        return 'has no stable name in /dev/disk/by-id'
    return ''


for disk in json.loads(sys.argv[1])['blockdevices']:
    if disk.get('type') != 'disk':
        continue
    reason = refusal(disk)
    size = f"{int(disk.get('size') or 0) / 2**30:.1f} GiB"
    model = ' '.join((disk.get('model') or '-').split())
    print('\t'.join(['no' if reason else 'ok', disk['name'], size, model,
                     reason or stable_path(disk['name'])]))
PYEOF
}

zfs_ask() {
  ZFS_ANSWER=""
  printf '%s' "$1"
  read -r ZFS_ANSWER <&3 || ZFS_ANSWER=""
  ZFS_ANSWER="${ZFS_ANSWER//$'\r'/}"
}

# Returns 1 when the person stopped, with nothing changed.
zfs_create_pool() {
  local pool="$1" list status name size model detail answer disk confirm
  local -a offered=() chosen=() paths=() vdev=()
  list="$(zfs_disks)" || die "could not check the disks, so nothing changed."

  echo
  echo "Disks on this server:"
  while IFS=$'\t' read -r status name size model detail; do
    [ -n "$name" ] || continue
    if [ "$status" = ok ]; then
      offered+=("$name")
      printf '  %-10s %-12s %-24s empty: %s\n' "$name" "$size" "$model" "$detail"
    else
      printf '  %-10s %-12s %-24s not offered: %s\n' "$name" "$size" "$model" "$detail"
    fi
  done <<<"$list"
  echo

  if [ "${#offered[@]}" -eq 0 ]; then
    die "no empty disk to use, so nothing changed. Add a second disk first (docs/ZFS_SETUP.md); on DigitalOcean choose Manually Format & Mount, because the automatic option formats it."
  fi
  if [ "${#offered[@]}" -eq 1 ]; then
    zfs_ask "Type the name of the disk for pool ${pool} (${offered[0]}), or press Enter to stop: "
  else
    zfs_ask "Type the name of the disk for pool ${pool}, two names for a mirror, or press Enter to stop: "
  fi
  read -ra chosen <<<"$ZFS_ANSWER"
  [ "${#chosen[@]}" -gt 0 ] || return 1
  [ "${#chosen[@]}" -le 2 ] || die "at most two disks, so nothing changed."
  if [ "${#chosen[@]}" -eq 2 ] && [ "${chosen[0]}" = "${chosen[1]}" ]; then
    die "a mirror needs two different disks, so nothing changed."
  fi

  echo
  echo "This ERASES:"
  for answer in "${chosen[@]}"; do
    disk=""
    while IFS=$'\t' read -r status name size model detail; do
      if [ "$status" = ok ] && [ "$name" = "$answer" ]; then
        disk="$detail"
        printf '  %-10s %-12s %-24s %s\n' "$name" "$size" "$model" "$detail"
      fi
    done <<<"$list"
    [ -n "$disk" ] || die "\"$answer\" is not one of the disks offered, so nothing changed."
    paths+=("$disk")
  done
  if [ "${#paths[@]}" -eq 2 ]; then
    vdev=(mirror)
  fi
  vdev+=("${paths[@]}")
  echo
  confirm="create ${pool}"
  zfs_ask "Type \"${confirm}\" to go ahead, anything else stops: "
  [ "$ZFS_ANSWER" = "$confirm" ] || return 1

  # Look again: the disk may have changed while the question was on the screen.
  list="$(zfs_disks)" || die "could not check the disks, so nothing changed."
  for answer in "${chosen[@]}"; do
    awk -F'\t' -v disk="$answer" '$1 == "ok" && $2 == disk { found = 1 } END { exit !found }' <<<"$list" \
      || die "$answer is no longer empty, so nothing changed."
  done

  info "Creating pool ${pool}"
  # Never -f: that is the switch that would overrule ZFS finding something on the disk.
  zpool create -m none -o ashift=12 -O compression=lz4 -O atime=off "$pool" "${vdev[@]}" \
    || die "zpool refused, so the pool was not created. Its message is above."
  zpool set autoexpand=on "$pool" || echo "warning: could not set autoexpand on ${pool}." >&2
}

# The cap's size comes from docs/ZFS_SETUP.md. An existing cap is somebody's decision.
zfs_cap_memory() {
  local conf="${ZFS_TEST_ROOT}/etc/modprobe.d/zfs.conf" total_kb suggested mib bytes
  if grep -qs zfs_arc_max "$conf"; then
    info "ZFS memory cache cap is already set in ${conf#"$ZFS_TEST_ROOT"}."
    return 0
  fi
  total_kb="$(awk '/^MemTotal:/ { print $2 }' "${ZFS_TEST_ROOT}/proc/meminfo")"
  if ! [[ "$total_kb" =~ ^[0-9]+$ ]]; then
    echo "warning: could not read the memory size; ZFS memory cache not capped." >&2
    return 0
  fi
  if [ "$total_kb" -le $((8 * 1024 * 1024)) ]; then suggested=512
  elif [ "$total_kb" -le $((16 * 1024 * 1024)) ]; then suggested=1024
  elif [ "$total_kb" -le $((32 * 1024 * 1024)) ]; then suggested=2048
  else suggested=4096
  fi
  echo
  zfs_ask "Cap the ZFS memory cache at ${suggested} MiB? Enter accepts, or type another size in MiB, or \"skip\": "
  mib="${ZFS_ANSWER:-$suggested}"
  if [ "$mib" = skip ]; then
    echo "ZFS memory cache not capped: it can use up to half the RAM."
    return 0
  fi
  if ! [[ "$mib" =~ ^[0-9]+$ ]] || [ "${#mib}" -gt 7 ] || [ "$mib" -lt 64 ]; then
    echo "warning: \"$mib\" is not a size of at least 64 MiB; ZFS memory cache not capped." >&2
    return 0
  fi
  bytes=$((mib * 1024 * 1024))
  if ! { mkdir -p "$(dirname "$conf")" && echo "options zfs zfs_arc_max=${bytes}" >>"$conf"; }; then
    echo "warning: could not write ${conf}; ZFS memory cache not capped." >&2
    return 0
  fi
  echo "$bytes" >"${ZFS_TEST_ROOT}/sys/module/zfs/parameters/zfs_arc_max" \
    || echo "warning: the cap applies from the next reboot." >&2
  info "ZFS memory cache capped at ${mib} MiB. Reserved Memory on the server's record must cover this plus the OS."
}

setup_zfs() {
  local configured pool health service
  local config="${ZFS_TEST_ROOT}${CONFIG_FILE}"
  if [ -f "$config" ]; then
    configured="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("zfs_parent", "-"))' "$config")" \
      || die "could not read ${CONFIG_FILE}, so nothing changed."
    [ -n "$configured" ] || die "this agent is installed without ZFS (zfs_parent is empty in ${CONFIG_FILE}), so nothing changed."
    if [ "$configured" != "-" ]; then
      if [ "$ZFS_PARENT_GIVEN" -eq 1 ] && [ "$ZFS_PARENT" != "$configured" ]; then
        die "--zfs-parent ${ZFS_PARENT} differs from ${configured} in ${CONFIG_FILE}, so nothing changed."
      fi
      ZFS_PARENT="$configured"
    fi
  fi
  python3 -c 'import re,sys; sys.exit(0 if re.fullmatch(r"[A-Za-z][A-Za-z0-9_.-]*(/[A-Za-z0-9_.-]+)+", sys.argv[1]) else 1)' "$ZFS_PARENT" \
    || die "invalid ZFS dataset \"$ZFS_PARENT\": expected pool/dataset, such as tank/dms."
  pool="${ZFS_PARENT%%/*}"

  if ! command -v zpool >/dev/null 2>&1; then
    info "Installing the ZFS tools"
    { DEBIAN_FRONTEND=noninteractive apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq zfsutils-linux; } </dev/null \
      || die "could not install zfsutils-linux."
  fi

  # Piped into bash, stdin is this script, so answers come from the terminal itself.
  if ! ( : <"${ZFS_TEST_ROOT}/dev/tty" ) 2>/dev/null; then
    die "the ZFS setup asks questions, so it needs a terminal. Run it from a console or SSH session."
  fi
  exec 3<"${ZFS_TEST_ROOT}/dev/tty" || die "could not open the terminal."

  if zpool list -H -o name "$pool" >/dev/null 2>&1; then
    info "Pool ${pool} already exists, so no disk was touched."
  elif ! zfs_create_pool "$pool"; then
    info "Stopped. Nothing changed."
    return 0
  fi
  if ! zfs list -H -o name "$ZFS_PARENT" >/dev/null 2>&1; then
    zfs create -p -o mountpoint=none "$ZFS_PARENT" || die "could not create ${ZFS_PARENT}."
  fi

  zfs_cap_memory

  health="$(zpool list -H -o health "$pool")" || die "could not read the state of pool ${pool}."
  [ "$health" = ONLINE ] || die "pool ${pool} is ${health}, not ONLINE. Check: zpool status ${pool}"
  for service in zfs-import-cache zfs-mount; do
    systemctl is-enabled --quiet "$service" \
      || echo "warning: ${service} is not enabled, so the pool may not come back after a reboot." >&2
  done
  info "ZFS is ready: pool ${pool} is ONLINE with ${ZFS_PARENT}. The server form shows it within a minute."
}

if [ "$SETUP_ZFS" -eq 1 ]; then
  [ "$WITH_ZFS" -eq 1 ] || die "--setup-zfs and --no-zfs cannot be used together."
  [ -z "$TUNNEL_ACTION" ] || die "--setup-zfs cannot be combined with a tunnel step. Run them separately."
  if [ -z "$CONTROL_URL" ]; then
    ( setup_zfs ) || exit 1
    exit 0
  fi
fi

if [ -n "$TUNNEL_ACTION" ]; then
  [ -f "$CONFIG_FILE" ] || die "${CONFIG_FILE} not found. Install the agent first."
  case "$TUNNEL_ACTION" in
    install)
      [ -n "$TUNNEL_CREDENTIALS_FILE" ] || die "--tunnel-only needs --tunnel-credentials-file"
      read_tunnel_credentials
      export DEBIAN_FRONTEND=noninteractive
      write_tunnel_settings "$TUNNEL_ID" ""
      install_tunnel || die "the tunnel is installed but not connected. Traffic has not moved."
      systemctl restart dms-agent
      info "Installed. Traffic has not moved. Test it, then run this again with --tunnel-cutover."
      ;;
    cutover)
      # Closing the public ports with no working tunnel would take every site down.
      python3 -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1])).get("tunnel_id") else 1)' "$CONFIG_FILE" \
        || die "no tunnel is installed here. Run --tunnel-only first."
      tunnel_connected || die "dms-tunnel is not connected to Cloudflare, so nothing changed. Check: journalctl -u dms-tunnel"
      switch_tunnel 1
      info "nginx now takes traffic from the tunnel only. The control plane moves DNS within a few minutes."
      ;;
    revert)
      switch_tunnel 0
      info "nginx has its public ports back. The control plane moves DNS within a few minutes."
      ;;
  esac
  exit 0
fi

[ -n "$CONTROL_URL" ] || { usage >&2; die "--url is required"; }
if [ "$SKIP_ENROLL" -eq 0 ] && [ -z "$ENROLL_TOKEN" ]; then
  usage >&2; die "--token is required (or pass --skip-enroll)"
fi
case "$CONTROL_URL" in
  https://*) ;;
  *) die "the control plane URL must be HTTPS: $CONTROL_URL" ;;
esac
# No "latest": the control plane decides which release a host gets, and the enrollment
# dialog names it, so every install is a version somebody published on purpose.
[ -n "$AGENT_VERSION" ] || die "--version is required. Copy the command from the host's enrollment dialog, which names the current release."
echo "$AGENT_VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+([.+-][0-9A-Za-z.-]+)?$' \
  || die "invalid --version: $AGENT_VERSION"
if [ -n "$TUNNEL_CREDENTIALS_FILE" ]; then
  read_tunnel_credentials
fi
if [ -n "$ARTIFACT_SHA256" ]; then
  echo "$ARTIFACT_SHA256" | grep -Eq '^[0-9a-f]{64}$' || die "invalid --sha256: $ARTIFACT_SHA256"
fi

# ---------------------------------------------------------------- prerequisites
. /etc/os-release 2>/dev/null || die "cannot read /etc/os-release"
case "${ID:-}" in
  ubuntu|debian) ;;
  *) die "this installer supports Ubuntu/Debian; found ${ID:-unknown}." ;;
esac

info "Installing prerequisites"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
PACKAGES="docker.io docker-compose-v2 python3-venv python3-pip git curl ca-certificates gnupg restic"
if [ "$WITH_ZFS" -eq 1 ]; then
  PACKAGES="$PACKAGES zfsutils-linux"
fi
# shellcheck disable=SC2086
apt-get install -y -qq $PACKAGES

if [ "$WITH_CROWDSEC" -eq 1 ]; then
  # The official repository, added explicitly rather than by piping their setup script
  # into a root shell. The agent owns the configuration (agent/dms_agent/crowdsec.py).
  info "Installing CrowdSec (detect-only until the control plane applies a mode)"
  install -d -m 755 /etc/apt/keyrings
  curl -fsSL https://packagecloud.io/crowdsec/crowdsec/gpgkey | gpg --dearmor --yes -o /etc/apt/keyrings/crowdsec.gpg
  echo "deb [signed-by=/etc/apt/keyrings/crowdsec.gpg] https://packagecloud.io/crowdsec/crowdsec/any any main" > /etc/apt/sources.list.d/crowdsec.list
  apt-get update -qq
  apt-get install -y -qq crowdsec
  # A fresh CrowdSec bans with its default rules at once. Detect only until someone has
  # looked at what it would ban (the same rule as on the Cloudpepper servers).
  cscli simulation enable --global >/dev/null
  if iptables --version 2>/dev/null | grep -q legacy; then
    apt-get install -y -qq crowdsec-firewall-bouncer-iptables
  else
    apt-get install -y -qq crowdsec-firewall-bouncer-nftables
  fi
  systemctl reload-or-restart crowdsec
fi
systemctl enable --now docker >/dev/null 2>&1 || true

if [ -n "$TUNNEL_CREDENTIALS_FILE" ]; then
  install_tunnel || echo "warning: continuing; the server form shows when the tunnel comes up." >&2
fi

if [ "$SETUP_ZFS" -eq 1 ]; then
  # A pool can be added later, so a problem here should not leave the agent uninstalled.
  ( setup_zfs ) || echo "warning: the ZFS setup did not finish; the install continues." >&2
fi
if [ "$WITH_ZFS" -eq 1 ] && ! zfs list -H -o name "$ZFS_PARENT" >/dev/null 2>&1; then
  cat >&2 <<EOF
warning: ZFS dataset "$ZFS_PARENT" does not exist yet, and nothing can be provisioned until it does.
         When the second disk is attached, run this installer again with only --setup-zfs.
EOF
fi

# ---------------------------------------------------------------- agent code
info "Installing the agent"
mkdir -p "${INSTALL_ROOT}/versions"

ARTIFACT_URL="${RELEASE_BASE}/v${AGENT_VERSION}/dms-agent-${AGENT_VERSION}.tar.gz"

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT
info "Fetching ${ARTIFACT_URL}"
curl -fsSL "$ARTIFACT_URL" -o "${WORKDIR}/agent.tar.gz" \
  || die "could not download the agent archive from ${ARTIFACT_URL}"
if [ -n "$ARTIFACT_SHA256" ]; then
  ACTUAL_SHA256="$(sha256sum "${WORKDIR}/agent.tar.gz" | cut -d' ' -f1)"
  [ "$ACTUAL_SHA256" = "$ARTIFACT_SHA256" ] \
    || die "the agent archive does not match the control plane's digest (got ${ACTUAL_SHA256}). Stop and investigate."
  info "Agent archive matches the control plane's digest"
else
  echo "warning: no --sha256 given; the agent archive was not checked against the control plane." >&2
fi
tar -xzf "${WORKDIR}/agent.tar.gz" -C "$WORKDIR"
SRC_DIR="$(find "$WORKDIR" -mindepth 1 -maxdepth 1 -type d | head -n1)"
[ -f "${SRC_DIR}/pyproject.toml" ] || die "the archive has no pyproject.toml"

RESOLVED_VERSION="$(sed -n "s/^__version__ = ['\"]\\(.*\\)['\"].*/\\1/p" \
  "${SRC_DIR}/dms_agent/__init__.py")"
[ -n "$RESOLVED_VERSION" ] || die "could not read the agent version from the archive"
[ "$RESOLVED_VERSION" = "$AGENT_VERSION" ] \
  || die "asked for ${AGENT_VERSION} but the archive contains ${RESOLVED_VERSION}"

PREFIX="${INSTALL_ROOT}/versions/${RESOLVED_VERSION}"
rm -rf "$PREFIX"
mkdir -p "$PREFIX"
python3 -m venv "${PREFIX}/venv"
"${PREFIX}/venv/bin/pip" install --quiet --disable-pip-version-check "$SRC_DIR"

# Atomic activation: the systemd unit runs ${INSTALL_ROOT}/current/venv/bin/python, so the
# swap below is what actually puts a version live. Self-updates use the same mechanism.
ln -sfn "$PREFIX" "${INSTALL_ROOT}/.current.new"
mv -Tf "${INSTALL_ROOT}/.current.new" "${INSTALL_ROOT}/current"
info "Installed dms-agent ${RESOLVED_VERSION} at ${PREFIX}"

# ---------------------------------------------------------------- configuration
mkdir -p "$CONFIG_DIR"
chmod 700 "$CONFIG_DIR"

if [ -n "$RELEASE_KEY_FILE" ]; then
  [ -f "$RELEASE_KEY_FILE" ] || die "release key file not found: $RELEASE_KEY_FILE"
else
  echo "warning: no --release-key given. This host cannot be upgraded remotely until" >&2
  echo "         release_public_key is set in ${CONFIG_FILE}." >&2
fi

# Values are passed as arguments, never interpolated into the Python source, so a URL or a
# dataset name containing quotes cannot change what this script does.
# Merge rather than overwrite: a re-run must not discard agent credentials or host-side
# switches an operator set by hand.
python3 - "$CONFIG_FILE" "$CONTROL_URL" "$INSTALL_ROOT" "$RELEASE_BASE" \
         "$([ "$WITH_ZFS" -eq 1 ] && echo "$ZFS_PARENT" || echo '')" \
         "$ALLOW_DESTRUCTIVE" "$RELEASE_KEY_FILE" <<'PYEOF'
import json, os, sys

path, control_url, install_root, release_base, zfs_parent, allow_destructive, key_file = sys.argv[1:8]

existing = {}
if os.path.exists(path):
    with open(path) as handle:
        existing = json.load(handle)

release_key = ''
if key_file:
    with open(key_file) as handle:
        release_key = handle.read()

defaults = {
    'control_plane_url': control_url.rstrip('/'),
    'state_dir': '/var/lib/dms-agent',
    'envs_root': '/srv/dms/envs',
    'code_root': '/srv/dms/code',
    'zfs_parent': zfs_parent,
    'proxy_network': 'dms-proxy',
    'install_root': install_root,
    'allow_destructive': allow_destructive == '1',
    'allow_agent_update': True,
    'shell_enabled': False,
    'allow_production_without_zfs': False,
    'release_public_key': release_key,
    'release_url_prefixes': [release_base],
}
# Host-side switches an operator already chose win over the defaults above.
for key, value in defaults.items():
    existing.setdefault(key, value)
# These three always follow the installer's arguments.
existing['control_plane_url'] = defaults['control_plane_url']
existing['install_root'] = defaults['install_root']
if release_key:
    existing['release_public_key'] = release_key

fd = os.open(path + '.tmp', os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, 'w') as handle:
    json.dump(existing, handle, indent=2)
os.replace(path + '.tmp', path)
print('wrote ' + path)
PYEOF

if [ -n "$TUNNEL_CREDENTIALS_FILE" ]; then
  # A new host starts on the tunnel. One already enrolled may be serving people, so moving it
  # stays a separate step.
  if python3 -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1])).get("agent_token") else 1)' "$CONFIG_FILE"; then
    write_tunnel_settings "$TUNNEL_ID" ""
    info "This host is already enrolled, so traffic has not moved. Use --tunnel-cutover when ready."
  else
    write_tunnel_settings "$TUNNEL_ID" 1
  fi
fi

mkdir -p /var/lib/dms-agent /srv/dms/envs /srv/dms/code
chmod 700 /var/lib/dms-agent

# ---------------------------------------------------------------- enrollment
if [ "$SKIP_ENROLL" -eq 0 ]; then
  if python3 -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1])).get("agent_token") else 1)' \
       "$CONFIG_FILE" 2>/dev/null; then
    info "Already enrolled; keeping the existing agent token."
  else
    info "Enrolling with ${CONTROL_URL}"
    "${INSTALL_ROOT}/current/venv/bin/python" -m dms_agent --config "$CONFIG_FILE" \
      enroll --url "$CONTROL_URL" --token "$ENROLL_TOKEN" \
      || die "enrollment failed. Enrollment tokens are single-use and expire after an hour."
  fi
fi

# ---------------------------------------------------------------- service
info "Installing the systemd unit"
cp "${SRC_DIR}/packaging/dms-agent.service" "$SERVICE_FILE"
systemctl daemon-reload
systemctl enable --now dms-agent

sleep 2
if systemctl is-active --quiet dms-agent; then
  info "dms-agent ${RESOLVED_VERSION} is running."
  echo
  echo "Follow it with:  journalctl -u dms-agent -f"
else
  echo "dms-agent did not start. Recent log:" >&2
  journalctl -u dms-agent -n 40 --no-pager >&2 || true
  exit 1
fi
