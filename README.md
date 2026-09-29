# crt

Minimal chroot manager. Creates and runs isolated rootfs environments using Linux namespace primitives — no Docker, no podman.

## How it works

`crt create` builds a rootfs directory. `crt run` executes commands inside it using `unshare` + `pivot_root` for isolation:

- **User namespace** (`--user --map-root-user`) — rootless; your UID maps to root inside
- **Mount namespace** (`--mount`) — mounts don't leak to the host
- **PID namespace** (`--pid`) — container has its own process tree
- **UTS namespace** (`--uts`) — container can set its own hostname
- **IPC namespace** (`--ipc`) — isolated shared memory
- **Net namespace** (`--net`, opt-in via `--net none`) — no host network, loopback only

`crt` enters the rootfs with `pivot_root` and detaches the old root, so the
host filesystem is gone from the container's mount tree — a process that is
root inside the namespace cannot walk back out to it. (Plain `chroot` can be
escaped by in-namespace root; `pivot_root` closes that.)

By default `$HOME` and the host `/tmp` are bind-mounted in. `/proc`, `/sys`,
`/dev`, and `/etc/resolv.conf` are mounted for a functional environment. The
`run` options below drop or replace these for running untrusted code.

The command inherits the caller's open file descriptors (above stdio), so a
parent process can hand it an IPC channel — e.g. Node's `NODE_CHANNEL_FD` from
a `fork()`/`spawn(..., {stdio: [...,'ipc']})` — and it works inside.

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
crt run [options] <name> <cmd>   Run command (flags override config; see below)
crt list                         List rootfs environments
crt rm     <name>                Remove rootfs
crt export <name> <binary>       Create host wrapper script for a binary
crt setup                        Enable memory/cpu limits (run once with sudo)
```

### `crt run` flags

Flags add to or override the stored config for a single invocation:

Short flags (`-v -e -m -c`) accept an attached (`-v/x:/y`) or separate (`-v /x:/y`) argument; long flags are equivalent. Options end at `--` or the `<name>`.

| Flag | Description |
|---|---|
| `-v`, `--volume` `/host:/container[:ro]` | Bind mount; `:ro` makes it read-only (verified, submounts included) |
| `-e`, `--env` `NAME[=val]` | Set env var; `NAME` with no `=` passes the caller's current value through |
| `-m`, `--memory` `SIZE` | Memory limit override (e.g. `256M`) |
| `-c`, `--cpus` `FLOAT` | CPU limit override (e.g. `1.5`) |
| `--net none\|host` | `none` = new network namespace, loopback only; default `host` shares the host stack |
| `--no-home` | Do not bind `$HOME` into the container |
| `--tmp private\|host` | `private` = fresh tmpfs on `/tmp`; default `host` binds the host `/tmp` |
| `--clean-env` | Start from an empty environment plus a minimal `PATH` and `HOME=/tmp`, then apply `-e` entries |
| `--ro-root` | Mount the rootfs itself read-only |

## Setup

Resource limits (`memory`/`cpus`) require a one-time root step to delegate a cgroup to your user. After that they work automatically on every `crt run`.

```sh
sudo crt setup
```

This:
1. Creates `/sys/fs/cgroup/user-$UID/` and delegates memory+cpu control to your user
2. On runit systems: installs `/etc/sv/crt-cgroup/` (backed by `/etc/crt-users`) so delegation persists across reboots

If `crt setup` hasn't been run, `crt run -m 512M ...` warns and continues without limits.

**Supported init systems:** runit (Void Linux). Other init systems receive manual startup instructions from `crt setup`.

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
image     ubuntu:22.04
packages  nodejs
mount     /data:/data
mount     /logs:/var/log/myapp:ro
env       FOO=bar
env       DEBUG=1
memory    512M
cpus      2
net       none
home      no
tmp       private
env-clean yes
root      ro
```

You can also pass a config file to `crt create`:

```sh
crt create myenv ./myenv.conf
```

The file is copied verbatim to `$CRT_HOME/myenv/config` and used as the source of truth for subsequent `crt run` invocations. Edit it directly to change defaults.

| Directive | Repeatable | Description |
|---|---|---|
| `image` | no | OCI image reference, or `void` for xbps bootstrap |
| `packages` | yes | Space-separated xbps packages installed after `base-minimal` (create time, Void only) |
| `mount` | yes | `hostpath:containerpath[:ro]` bind mount |
| `env` | yes | `NAME=val`, or `NAME` alone to pass the caller's value through |
| `memory` | no | Memory limit: `512M`, `2G`, etc. |
| `cpus` | no | CPU limit as a float: `2`, `0.5` |
| `net` | no | `none` for a private network namespace, or `host` (default) |
| `home` | no | `no` to skip the `$HOME` bind (default binds it) |
| `tmp` | no | `private` for a tmpfs `/tmp`, or `host` (default) |
| `env-clean` | no | `yes` to start from a clean minimal environment |
| `root` | no | `ro` to mount the rootfs read-only (default `rw`) |

The `packages` directive is honored only when creating a Void (xbps) rootfs
from a config file, e.g. `crt create sandbox ./sandbox.conf`.

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
| `crt run` / `crt enter` | `unshare`, `pivot_root`, `chroot` (util-linux) |
| `crt setup` | root or `sudo` |

`unshare`, `pivot_root`, and `chroot` are in `util-linux`, present on any Linux system. `curl` and `jq` are only needed for OCI pulls. Read-only bind verification and `--tmp private` use kernel features present on any modern (5.x) kernel.

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
  .cache/
    layers/      ← OCI layer blobs, keyed by digest
```

Rootfs directories are self-contained and can be moved, copied, or archived with `tar`.

OCI layers are cached in `.cache/layers/` and reused across environments. There is no automatic eviction — run `rm -rf $CRT_HOME/.cache` to clear.

## Testing

```sh
bash test/test-crt.sh         # mock-level: parsing and generated calls, no root
bash test/test-isolation.sh   # real namespaces; skips if userns is unavailable
```

`test/test-crt.sh` uses PATH-based mocks (`test/mocks/`) that shadow system commands:

| Mock | Replaces | What it does |
|---|---|---|
| `unshare` | util-linux | Logs its args (when `CRT_MOCK_LOG` is set), strips namespace flags, runs the inner script on the host |
| `pivot_root` | util-linux | Always fails, so `cmd_run` falls back to `chroot` (no real mount namespace under test) |
| `chroot` | util-linux | Drops the rootfs arg, runs the command on the host filesystem |
| `mount` | util-linux | Logs its args (when `CRT_MOCK_LOG` is set), then no-op |
| `curl` | curl | Returns canned token/manifest JSON and a generated tar for blob requests |
| `xbps-install` | xbps | Creates a minimal `bin/sh` skeleton in the rootfs |

This lets the full `cmd_create` and `cmd_run` code paths run without root, namespaces, network, or xbps. 90 tests cover `parse_memory`, `read_config` (including the `net`/`home`/`tmp`/`env-clean`/`root`/`packages` directives), `write_config`, `parse_image_ref`, all three `create` dispatch paths, `run` flag and config merging, the generated `unshare`/`mount` calls for each isolation flag, clean-env behavior, inherited file descriptors, `list`, `rm`, OCI layer cache reuse, `export`, and `setup`.

`test/test-isolation.sh` builds a throwaway rootfs that reuses the host `/usr` (bind-mounted read-only) and proves, in real namespaces, that `--net none` blocks the network, `--no-home` hides `$HOME`, `--tmp private` hides the host `/tmp`, `:ro` binds reject writes, `--clean-env` drops caller variables while keeping passed-through ones, and an inherited fd is readable inside.

## Limitations

- No private registry authentication
- Resource limits (`memory`/`cpus`) require one-time root setup — run `sudo crt setup` (see [Setup](#setup))
- `--net none` isolates the network but provides no NAT/bridge, so the container has loopback only (no outbound access)
