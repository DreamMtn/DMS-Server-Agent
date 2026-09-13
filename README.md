# DMS Server Agent

The agent that Dream Mountain Services runs on hosts we manage. It performs a fixed set of
operations — provision, deploy, back up, restart, roll back — and reports status to the
hosting control plane.

This repository holds the **installer** and the **signed agent releases**. It is public on
purpose: see [Why this is public](#why-this-is-public).

---

## Installing on a host

You will be given an **enrollment token** (valid one hour, single use) and the **release
public key** by Dream Mountain.

```bash
curl -fsSL https://raw.githubusercontent.com/DreamMtn/DMS-Server-Agent/main/install.sh \
  | sudo bash -s -- --url https://hosting-api.dreammtn.com --token <enrollment token> \
                    --zfs-parent tank/dms --release-key /path/to/release_key.pub.pem
```

### Verify before running it (recommended for production)

That one-liner pipes a script from the internet into a root shell. For any host that matters,
check it first. The expected digest and the release key fingerprint are shown in the
enrollment dialog in the control plane, which is authenticated — this repository is not.

```bash
curl -fsSL https://raw.githubusercontent.com/DreamMtn/DMS-Server-Agent/main/install.sh \
  -o /tmp/dms-install.sh
sha256sum /tmp/dms-install.sh          # compare with the enrollment dialog
sudo bash /tmp/dms-install.sh --url ... --token ... --release-key ...
```

If the two do not match, **stop** and contact us.

### Options

| Flag | Meaning |
|---|---|
| `--url` | Control plane URL the agent will call. Stored permanently; HTTPS only. |
| `--token` | One-time enrollment token from the host record. |
| `--zfs-parent` | ZFS parent dataset for environments (default `tank/dms`). |
| `--no-zfs` | Host has no ZFS pool. Production environments refuse to provision without it, because there would be no snapshot to roll back to. |
| `--release-key` | PEM file with the agent release public key. **Without it the host cannot be upgraded remotely.** |
| `--allow-destructive` | Permit rollback, restore, prune and remove jobs. Intended for stage hosts; leave off on production. |
| `--version` | Install a specific version instead of the latest. |
| `--skip-enroll` | Install and configure without contacting the control plane. |

The installer needs Ubuntu or Debian and installs Docker, restic, and a Python virtualenv.
Re-running it is safe: existing credentials and host-side switches are kept.

### The ZFS pool is yours to create

The installer does not touch your disks. Create the pool before provisioning anything:

```bash
zpool create -o ashift=12 tank /dev/disk/by-id/<device>
zfs set compression=lz4 tank && zfs set atime=off tank
zfs create -o mountpoint=none tank/dms
echo "options zfs zfs_arc_max=4294967296" > /etc/modprobe.d/zfs.conf   # cap the ARC
```

---

## What the agent does on your server

- **Outbound HTTPS only.** It polls the control plane; nothing connects *to* it. No inbound
  ports, no port forwarding, nothing to expose through your firewall.
- **A fixed set of operations.** There is deliberately no "run this command" instruction.
  The agent will not execute anything the control plane asks of it outside that list.
- **Every instruction is signed.** Jobs carry an Ed25519 signature the agent verifies before
  acting, along with the host it was issued for and an expiry.
- **Switches you control.** `allow_destructive`, `shell_enabled` and
  `allow_production_without_zfs` live in `/etc/dms-agent/config.json` on your server. The
  control plane cannot change them. If destructive operations are off, they stay off.
- **Updates are signed by an offline key.** The agent installs a new version only if it is
  signed by a key that is not held on the control plane — so even a compromise of our
  hosting platform cannot push code to your server.

Useful paths:

| Path | What it is |
|---|---|
| `/etc/dms-agent/config.json` | Configuration and credentials (root-only) |
| `/opt/dms-agent/current` | Symlink to the running version |
| `/opt/dms-agent/versions/` | Installed versions, kept for rollback |
| `/srv/dms/envs/<slug>` | An environment's data |
| `journalctl -u dms-agent -f` | What it is doing right now |

---

## Releases

Each release is a signed tarball attached to a [GitHub
Release](https://github.com/DreamMtn/DMS-Server-Agent/releases). The signature covers the
version and the exact bytes of the archive, so a release cannot be swapped for another build
or replayed under a different version number.

The tarball is the agent's source. Extract it and read it — that is the point.

---

## Why this is public

Because hiding it would protect nothing and cost something.

The agent runs as root on **your** hardware. You can read its memory, trace its syscalls and
inspect its traffic whatever language it is written in — so there is no version of this that
keeps secrets from the machine's owner. Every security property here rests on keys we hold,
not on code you cannot see: publishing the source does not help anyone forge a signed job or
ship a signed release.

And you should be able to read it. This is a root process on your server that talks to us.
"Here is exactly what it does" is a better answer than a binary you are asked to trust, and
for customers under ITAR or CMMC an assessor may need to review it.

What this repository does **not** contain is the hosting control plane — that is a separate,
private system. You get the agent that runs on your box, and nothing else.

---

## Security contact

Found something? Email **security@dreammtn.com** rather than opening a public issue, and we
will come back to you.
