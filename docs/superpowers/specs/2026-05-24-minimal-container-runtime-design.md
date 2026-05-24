# Minimal Container Runtime — Design Spec

**Date:** 2026-05-24
**Status:** Approved

## Goal

Remove the podman dependency from `crt` entirely. Replace it with:
- xbps-based rootfs bootstrap (Void Linux, default)
- Pure-shell OCI image pull (multi-registry fallback)
- `unshare` + `chroot` for isolated container execution

The script remains a single file. Existing rootfs directories created by the old podman-based `crt` are fully compatible.

---

## Section 1: Bootstrap (`cmd_create`)

### Interface

```
crt create <name>                  # xbps bootstrap (Void Linux)
crt create <name> ubuntu:22.04     # OCI pull (Docker Hub)
crt create <name> ghcr.io/u/img:tag  # OCI pull (ghcr.io)
```

Detection: if the second argument is absent, use xbps. If present, parse as an image reference and use the OCI path.

### xbps Path

```bash
xbps-install -r "$rootfs" --repository="${VOID_REPO:-https://repo-default.voidlinux.org/current}" -y base-minimal
```

`VOID_REPO` is overridable via environment variable for mirrors or local repos.

### OCI Path

Parse the image reference into `registry`, `repo`, and `tag`:

| Input | Registry | Repo | Tag |
|---|---|---|---|
| `ubuntu:22.04` | registry-1.docker.io | library/ubuntu | 22.04 |
| `user/image:tag` | registry-1.docker.io | user/image | tag |
| `ghcr.io/user/img:tag` | ghcr.io | user/img | tag |
| `quay.io/user/img:tag` | quay.io | user/img | tag |

Default tag is `latest` if omitted. Images without a slash prefix on Docker Hub get the `library/` prefix.

---

## Section 2: OCI Pull Internals

Three helper functions. Dependencies for this path: `curl`, `jq`, `tar`.

### `oci_token <registry> <repo>`

Routes to the correct auth endpoint and returns a bearer token:

| Registry | Token endpoint |
|---|---|
| registry-1.docker.io | `https://auth.docker.io/token?service=registry.docker.io&scope=repository:$repo:pull` |
| ghcr.io | `https://ghcr.io/token?scope=repository:$repo:pull` |
| quay.io | `https://quay.io/v2/auth?service=quay.io&scope=repository:$repo:pull` |
| other | `https://$registry/v2/auth?scope=repository:$repo:pull` |

Private registries with credentials are out of scope.

### `oci_manifest <registry> <repo> <tag> <token>`

Fetches the manifest with both Docker v2 and OCI media type `Accept` headers. If the response is an image index (multi-arch list, `mediaType` contains `index`), selects the entry matching the host architecture (`uname -m` mapped to `amd64`/`arm64`). Returns a single-platform manifest JSON.

### `oci_unpack <registry> <repo> <token> <manifest> <rootfs>`

Iterates layers in manifest order. For each layer:

1. Stream blob via `curl` through `tar -xzf -` into `$rootfs`
2. Process whiteout files:
   - `.wh.<name>` → `rm -rf "$rootfs/<dir>/<name>"`
   - `.wh..wh..opq` → clear the containing directory (opaque whiteout)

Whiteout processing runs per-layer after unpacking, before moving to the next layer.

---

## Section 3: Runtime (`cmd_run` / `cmd_enter`)

### Namespace Isolation

Replaces `podman run --rootfs` with:

```bash
unshare --user --map-root-user --mount --pid --uts --ipc --fork \
  bash -c "
    mount -t proc proc '$rootfs/proc'
    mount -t sysfs sysfs '$rootfs/sys'
    mount --bind /dev '$rootfs/dev'
    mount --bind /dev/pts '$rootfs/dev/pts'
    mount --bind /etc/resolv.conf '$rootfs/etc/resolv.conf'
    exec chroot '$rootfs' '$@'
  "
```

| Flag | Effect |
|---|---|
| `--user --map-root-user` | Process appears as root inside (rootless) |
| `--mount` | Mounts don't escape to host |
| `--pid` | Isolated PID tree |
| `--uts` | Container can set its own hostname |
| `--ipc` | Isolated IPC/shared memory |
| `--fork` | Required with `--pid` to become PID 1 |

### Preserved Behaviors from Podman Version

- `$HOME` and `/tmp` are bind-mounted into the container
- Working directory is set to `$(pwd)` inside the container via `cd "$(pwd)"` in the unshare wrapper before exec
- TTY detection: `-t` flag passed when stdin is a terminal

### `cmd_enter`

Unchanged — thin wrapper calling `cmd_run` with `/bin/bash -l`.

---

## Section 4: Unchanged Commands

`cmd_list`, `cmd_rm`, and `cmd_export` are pure shell and require no changes.

---

## Summary of Changes

| Function | Change |
|---|---|
| `cmd_create` | Rewritten — xbps or OCI path, no podman |
| `cmd_run` | Rewritten — unshare+chroot, no podman |
| `cmd_enter` | Unchanged |
| `cmd_list` | Unchanged |
| `cmd_rm` | Unchanged |
| `cmd_export` | Unchanged |
| `oci_token` | New helper |
| `oci_manifest` | New helper |
| `oci_unpack` | New helper |

## Runtime Dependency Changes

| Task | Was | Now |
|---|---|---|
| Bootstrap (Void) | podman | xbps-install |
| Bootstrap (OCI) | podman | curl, jq, tar |
| Run/enter | podman | unshare, chroot (util-linux) |

`curl` and `jq` are only required when using the OCI image path.
Estimated net addition: ~150 lines.
