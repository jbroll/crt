# crt

Minimal chroot manager. Creates and runs isolated rootfs environments using Linux namespace primitives — no Docker, no podman.

See [docs/architecture.md](docs/architecture.md) for how it's built.

## How it works

`crt create` builds a rootfs directory. `crt run` executes commands inside it using `unshare` + `pivot_root` for isolation:

- **User namespace** (`--user --map-root-user`) — rootless; your UID maps to root inside
- **Mount namespace** (`--mount`) — mounts don't leak to the host
- **PID namespace** (`--pid`) — container has its own process tree
- **UTS namespace** (`--uts`) — container can set its own hostname
- **IPC namespace** (`--ipc`) — isolated shared memory
- **Net namespace** (`--net`, opt-in via `--net none`) — no host network, loopback only

`crt` enters the rootfs with `pivot_root` and unconditionally detaches the old
root, so the host filesystem is gone from the container's mount tree — a
process that is root inside the namespace cannot walk back out to it. (Plain
`chroot` can be escaped by in-namespace root; `pivot_root` closes that.) It
verifies the old root is gone and aborts if it is not.

By default `$HOME` and the host `/tmp` are bind-mounted in, `/proc` and
`/etc/resolv.conf` are set up, and a minimal `/dev` is built (only `null`,
`zero`, `full`, `random`, `urandom`, `tty`, a fresh `devpts`, and a private
`/dev/shm`). The host `/dev` is never bind-mounted whole, so container block and
input devices are never exposed. The `run` options below drop or replace the
host bindings for running untrusted code.

### Hardened mode

Any isolation option (`--net none`, `--no-home`, `--tmp private`, a `:ro` bind,
`--clean-env`, or `--ro-root`) turns on hardened mode:

- **Fail closed.** Every mount and setup step the isolation depends on must
  succeed or `crt` exits non-zero before the command runs. There is no silent
  fallback to `chroot` when `pivot_root` fails.
- **No capabilities.** After the mounts are set up and the old root detached,
  the command is exec'd through `setpriv --no-new-privs --bounding-set=-all
  --inh-caps=-all --ambient-caps=-all`. It runs as uid 0 (so it can write files
  the caller owns in `rw` binds) but with an empty capability set, so it cannot
  remount a `:ro` bind read-write, remount the root, unmount a bind to expose
  what is under it, or create new mounts.
- **Read-only binds verified.** A `:ro` bind is remounted read-only (recursively
  where the kernel supports it) and then checked with `findmnt`; a still-writable
  mount or submount aborts the run.
- **Trusted binaries, clean env.** `crt` resolves every helper it runs
  (`unshare`, and inside the namespace `mount`, `pivot_root`, `umount`,
  `findmnt`, `realpath`, `setpriv`, …) by absolute path from a fixed trusted
  `PATH`, never the caller's, and `setpriv` is exec'd absolutely. `-e`/`env`
  values are never exported into `crt` itself — they are applied to the command
  only — so a caller-supplied `PATH`/`LD_PRELOAD` cannot hijack `crt`.
- **Symlink-safe setup.** Every path `crt` writes or mounts before `pivot_root`
  (`/dev/*`, `/etc/resolv.conf`, `/proc`, `/tmp`, the bind targets) is resolved
  with `realpath` and refused if it escapes the rootfs; a symlink planted at a
  leaf (e.g. `/etc/resolv.conf`) is removed rather than followed. A poisoned
  rootfs from an earlier run cannot redirect setup to a host path.

Without any isolation option, `crt run` behaves as before: the command runs as
root with capabilities, so `crt run ubuntu apt install -y perl` still works.

### File descriptors

File descriptors above stderr are closed before the command runs, except those
named with `--keep-fd N` (repeatable) and — when `-e NODE_CHANNEL_FD` is passed
— the fd named by `NODE_CHANNEL_FD`, but only if it is actually open and above
stderr. This lets a parent hand the command an IPC channel, e.g. Node's
`fork()`/`spawn(..., {stdio: [...,'ipc']})`, while a fd the caller leaked without
`O_CLOEXEC` does not become a handle outside the sandbox.

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
| `--keep-fd N` | Keep file descriptor `N` open in the command (repeatable); otherwise fds above stderr are closed |

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
| `keep-fd` | yes | Space-separated fd numbers to keep open in the command |

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
| `crt run` (hardened) | also `setpriv`, `findmnt` (util-linux) and `realpath` (coreutils), inside the rootfs |
| `crt setup` | root or `sudo` |

`unshare`, `pivot_root`, `chroot`, `setpriv`, and `findmnt` are in `util-linux`, present on any Linux system. In hardened mode `setpriv`, `findmnt`, and `realpath` must exist **inside the rootfs** (they run after `pivot_root`); a Void `base-minimal` or the `-v /usr:/usr:ro` used for the eval sandbox provides them. `curl` and `jq` are only needed for OCI pulls. Read-only bind verification and `--tmp private` use kernel features present on any modern (5.x) kernel.

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
| `pivot_root` | util-linux | Always fails, so in test mode `cmd_run` falls back to `chroot` (no real mount namespace under test) |
| `chroot` | util-linux | Drops the rootfs arg, runs the command on the host filesystem |
| `mount` | util-linux | Logs its args (when `CRT_MOCK_LOG` is set), then no-op |
| `curl` | curl | Returns canned token/manifest JSON and a generated tar for blob requests |
| `xbps-install` | xbps | Creates a minimal `bin/sh` skeleton in the rootfs |

`test/test-crt.sh` sets `CRT_TEST_MODE` to the mocks directory, which carries a
marker file (`test/mocks/.crt-mocks`). Test mode is enabled only when
`CRT_TEST_MODE` names such a directory: it routes `crt`'s binary resolution
through the mocks, lets `cmd_run` fall back to `chroot`, and skips read-only
verification when the mock `pivot_root` fails. A bare `CRT_TEST_MODE=1` inherited
by a production run does nothing. This lets the full `cmd_create` and `cmd_run`
code paths run without root, namespaces, network, or xbps. 101 tests cover
`parse_memory`, `read_config` (including the
`net`/`home`/`tmp`/`env-clean`/`root`/`packages`/`keep-fd` directives),
`write_config`, `parse_image_ref`, all three `create` dispatch paths, `run` flag
and config merging, the generated `unshare`/`mount` calls for each isolation
flag, clean-env behavior, `--keep-fd`/fd closing and the `NODE_CHANNEL_FD`
guards, the marker-gated test-mode switch, `list`, `rm`, OCI layer cache reuse,
`export`, and `setup`.

`test/test-isolation.sh` builds a throwaway rootfs that reuses the host `/usr`
(bind-mounted read-only) and proves, in real namespaces, mostly from one run
with the full flag set (`--net none --no-home --tmp private --clean-env
--ro-root` plus a `:ro` bind and `--keep-fd`): the old root is gone, the command
is capless (cannot remount, unmount, or create mounts), `$HOME` and the host
`/tmp` are hidden, the minimal `/dev` has no block/input devices but a working
`/dev/null`, `:ro` binds reject writes, the clean environment is minimal, a kept
fd is readable while an unlisted one is closed, `NODE_CHANNEL_FD` is kept
automatically, `--net none` blocks the network, and a default run is unchanged
(uid 0 with capabilities, `$HOME` visible). It also checks that an `-e PATH`
cannot substitute `crt`'s `unshare`, that a PATH-planted `setpriv` is not used
(caps still dropped), and that planted `resolv.conf`/`/dev` symlinks in the
rootfs are not followed. 29 checks.

## Limitations

- No private registry authentication
- Resource limits (`memory`/`cpus`) require one-time root setup — run `sudo crt setup` (see [Setup](#setup))
- `--net none` isolates the network but provides no NAT/bridge, so the container has loopback only (no outbound access)
