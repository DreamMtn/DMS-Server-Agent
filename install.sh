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
ALLOW_DESTRUCTIVE=0
SKIP_ENROLL=0
WITH_CROWDSEC=1
RELEASE_KEY_FILE=""

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
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --url) CONTROL_URL="${2:?--url needs a value}"; shift 2 ;;
    --token) ENROLL_TOKEN="${2:?--token needs a value}"; shift 2 ;;
    --zfs-parent) ZFS_PARENT="${2:?--zfs-parent needs a value}"; shift 2 ;;
    --no-zfs) WITH_ZFS=0; shift ;;
    --allow-destructive) ALLOW_DESTRUCTIVE=1; shift ;;
    --release-key) RELEASE_KEY_FILE="${2:?--release-key needs a value}"; shift 2 ;;
    --version) AGENT_VERSION="${2:?--version needs a value}"; shift 2 ;;
    --sha256) ARTIFACT_SHA256="${2:?--sha256 needs a value}"; shift 2 ;;
    --skip-enroll) SKIP_ENROLL=1; shift ;;
    --no-crowdsec) WITH_CROWDSEC=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown option $1" ;;
  esac
done

[ "$(id -u)" -eq 0 ] || die "run this as root (sudo)."
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

if [ "$WITH_ZFS" -eq 1 ] && ! zfs list -H -o name "$ZFS_PARENT" >/dev/null 2>&1; then
  cat >&2 <<EOF
warning: ZFS dataset "$ZFS_PARENT" does not exist yet.
         Create the pool and dataset before provisioning anything, e.g.:
           zpool create -o ashift=12 tank /dev/disk/by-id/<device>
           zfs set compression=lz4 tank && zfs set atime=off tank
           zfs create -o mountpoint=none tank/dms
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
