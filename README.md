# crt

Minimal chroot manager. Creates and runs isolated rootfs environments using Linux namespace primitives — no Docker, no podman.

## How it works

`crt create` builds a rootfs directory. `crt run` executes commands inside it using `unshare` + `chroot` for isolation:

- **User namespace** (`--user --map-root-user`) — rootless; your UID maps to root inside
- **Mount namespace** (`--mount`) — mounts don't leak to the host
- **PID namespace** (`--pid`) — container has its own process tree
- **UTS namespace** (`--uts`) — container can set its own hostname
- **IPC namespace** (`--ipc`) — isolated shared memory

`$HOME` and `/tmp` are bind-mounted in. `/proc`, `/sys`, `/dev`, and `/etc/resolv.conf` are mounted for a functional environment.

## Installation

```sh
cp crt /usr/local/bin/crt
chmod +x /usr/local/bin/crt
```

## Usage

```
crt create <name>                Bootstrap Void Linux rootfs (xbps)
crt create <name> <image>        Pull rootfs from OCI registry
crt enter  <name>                Interactive shell
crt run [-v h:c] [-e K=v] [-m SIZE] [-c N] <name> <cmd>  Run command (flags override config)
crt list                         List rootfs environments
crt rm     <name>                Remove rootfs
crt export <name> <binary>       Create host wrapper script for a binary
```

### `crt run` flags

Flags add to or override the stored config for a single invocation:

| Flag | Description |
|---|---|
| `-v /host:/container` | Additional bind mount |
| `-e KEY=val` | Additional or override env var |
| `-m SIZE` | Memory limit override (e.g. `256M`) |
| `-c FLOAT` | CPU limit override (e.g. `1.5`) |

## Creating environments

**Void Linux (default, no image required):**

```sh
crt create myenv
```

Uses `xbps-install` to bootstrap `base-minimal` into a new rootfs directory. Fast, no network image pull.

**From an OCI registry:**

```sh
crt create ubuntu ubuntu:22.04
crt create alpine alpine:3.19
crt create myapp ghcr.io/user/myapp:latest
crt create staging quay.io/org/service:v2.1
```

Supported registries: Docker Hub, ghcr.io, quay.io, and any registry implementing the OCI Distribution Spec. Public images only (no credential support). Multi-arch image indexes are handled — the layer matching the host architecture is selected automatically.

## Running commands

```sh
# one-off command
crt run ubuntu dpkg -l

# interactive shell
crt enter ubuntu

# working directory is preserved
cd /home/john/project
crt run ubuntu make install    # runs in /home/john/project inside the container
```

## Config files

Each environment stores its config at `$CRT_HOME/<name>/config`:

```
image  ubuntu:22.04
mount  /data:/data
mount  /logs:/var/log/myapp
env    FOO=bar
env    DEBUG=1
memory 512M
cpus   2
```

You can also pass a config file to `crt create`:

```sh
crt create myenv ./myenv.conf
```

The file is copied verbatim to `$CRT_HOME/myenv/config` and used as the source of truth for subsequent `crt run` invocations. Edit it directly to change defaults.

| Directive | Repeatable | Description |
|---|---|---|
| `image` | no | OCI image reference, or `void` for xbps bootstrap |
| `mount` | yes | `hostpath:containerpath` bind mount |
| `env` | yes | `KEY=val` environment variable |
| `memory` | no | Memory limit: `512M`, `2G`, etc. |
| `cpus` | no | CPU limit as a float: `2`, `0.5` |

## Exporting binaries

Creates a wrapper script in `CRT_BIN` that calls `crt run <name> <binary>` transparently:

```sh
crt export ubuntu perl
crt export ubuntu /usr/bin/python3 python
```

Add `CRT_BIN` to your `PATH` and the binary behaves as if installed on the host.

## Environment variables

| Variable | Default | Description |
|---|---|---|
| `CRT_HOME` | `/home/crt` | Where rootfs directories are stored |
| `CRT_BIN` | `/home/crt/bin` | Where exported wrapper scripts are placed |
| `VOID_REPO` | `https://repo-default.voidlinux.org/current` | xbps repository for Void bootstrap |

## Runtime dependencies

| Operation | Requires |
|---|---|
| `crt create <name>` (Void) | `xbps-install` |
| `crt create <name> <image>` (OCI) | `curl`, `jq`, `tar` |
| `crt run` / `crt enter` | `unshare`, `chroot` (util-linux) |

`unshare` and `chroot` are in `util-linux`, present on any Linux system. `curl` and `jq` are only needed for OCI pulls.

User namespace support must be enabled on the host kernel (`/proc/sys/kernel/unprivileged_userns_clone` = 1 on some distros).

## Storage layout

Each environment is a plain directory under `CRT_HOME`:

```
/home/crt/
  ubuntu/        ← rootfs for 'ubuntu'
    bin/
    etc/
    usr/
    …
  myenv/         ← rootfs for 'myenv'
  bin/           ← CRT_BIN: exported wrapper scripts
    perl
    python
```

Rootfs directories are self-contained and can be moved, copied, or archived with `tar`.

## Testing

```sh
bash test/test-crt.sh
```

Tests use PATH-based mocks (`test/mocks/`) that shadow system commands:

| Mock | Replaces | What it does |
|---|---|---|
| `unshare` | util-linux | Strips namespace flags, runs the inner script directly on the host |
| `chroot` | util-linux | Drops the rootfs arg, runs the command on the host filesystem |
| `mount` | util-linux | No-op (no namespace needed) |
| `curl` | curl | Returns canned token/manifest JSON and a generated tar for blob requests |
| `xbps-install` | xbps | Creates a minimal `bin/sh` skeleton in the rootfs |

This lets the full `cmd_create` and `cmd_run` code paths run without root, namespaces, network, or xbps. 40 tests cover `parse_memory`, `read_config`, `write_config`, all three `create` dispatch paths, `run` flag and config merging, `list`, and `rm`.

## Limitations

- No network isolation (host network stack is shared)
- OCI layers are cached at `$CRT_HOME/.cache/layers/` (no automatic eviction — `rm -rf $CRT_HOME/.cache` to clear)
- No private registry authentication
- Resource limits (`memory`/`cpus`) require cgroup v2 with user delegation; degrade gracefully with a warning if unavailable
