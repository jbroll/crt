# crt

Minimal chroot manager. Creates and runs isolated rootfs environments using Linux namespace primitives — no Docker, no podman.

See [docs/architecture.md](docs/architecture.md) for how it's built and
[docs/backlog.md](docs/backlog.md) for outstanding work.

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

### Trust model

**Hardened mode protects the host from the workload inside a hardened run.
Default mode is not a sandbox.** A default (non-hardened) run has your
authority over the host: it binds `$HOME` and `/tmp` read-write, keeps full
capabilities in its user namespace, and runs the rootfs's own `umount` while
the host tree is still attached. Code in a default run can change any file
you can, including any rootfs under `CRT_HOME`, its config, and its pristine
marker, and crt does not try to stop it.

So the integrity of every hardened rootfs depends on **never running
untrusted code in default mode, in any rootfs, as the same user** — including
`crt enter` and package installs you do not trust. Use hardened mode for
untrusted code, and only ever run the rootfs it uses hardened. Details and
residuals: [docs/architecture.md § Trust model](docs/architecture.md#trust-model).

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
- **Read-only, pristine rootfs required.** The old-root detach and capability
  drop after `pivot_root` run the rootfs's own `umount`/`setpriv` while still
  privileged, so a hardened run trusts the rootfs is unmodified. `crt create`
  writes a pristine marker, `$CRT_HOME/.state/<name>.pristine`, recording the
  rootfs's canonical path and device:inode. A hardened run requires a matching
  marker and forces the rootfs read-only; every non-hardened run of it deletes
  the marker before it starts (and does not start if it can't). A rootfs that
  was run writable through crt, migrated from an in-rootfs config, aliased,
  copied, or not made by `crt create` has no matching marker and is refused.
  The marker cannot see a default run of one rootfs writing into another (see
  [Trust model](#trust-model)), nor a rename-and-back or an `rm`/`mkdir` that
  reuses the inode; recreate a rootfs with `crt rm` then `crt create`, never by
  hand. To use a rootfs for untrusted code, create it and only ever run it
  hardened (put `root ro` in its config).
- **CRT_HOME out of reach.** A hardened run is refused unless `CRT_HOME` lies
  outside `$HOME`, `/tmp` and the host side of every `mount` line in every
  stored config. It is also refused if any of its own binds, `:ro` included,
  is, contains, or sits inside `CRT_HOME`, `.config` or `.state` (compared
  after `realpath`). `/data/crt/home/<user>` and `/home/crt` are fine; keep
  `CRT_HOME` outside `$HOME`. `crt doctor` checks this.

Without any isolation option, `crt run` behaves as before: the command runs as
root with capabilities, so `crt run ubuntu apt install -y perl` still works
(and removes the pristine marker, so a later hardened run of it is refused).

The stored config never lives inside a rootfs (see [Config files](#config-files)),
so a container cannot read or rewrite the config that governs its own — or a
later — run. Rootfs names are single path components: letters, digits, `.`,
`_`, `-`, starting with a letter or digit.

### File descriptors

File descriptors above stderr are closed before the command runs, except those
named with `--keep-fd N` (repeatable) and — when `-e NODE_CHANNEL_FD` is passed
— the fd named by `NODE_CHANNEL_FD`, but only if it is actually open and above
stderr. This lets a parent hand the command an IPC channel, e.g. Node's
`fork()`/`spawn(..., {stdio: [...,'ipc']})`, while a fd the caller leaked without
`O_CLOEXEC` does not become a handle outside the sandbox.

## Installation

On a multi-user host, install into the `/data` layout once, then set up each
user, service accounts included:

```sh
sudo ./crt install              # /data/crt/bin/crt, linked from /usr/local/bin/crt
sudo crt setup john s-ci        # cgroup delegation + /data/crt/home/<user>
crt doctor                      # as each user: is hardened mode ready?
```

The layout:

```
/data/crt/              root, 755
  bin/crt               the installed script, root, 755 (users cannot change it)
  home/<user>/          that user's CRT_HOME, owned by the user, 700
    <rootfs>/ .config/ .state/ .cache/ bin/
```

`crt install [--prefix DIR]` copies the running script to `DIR/bin/crt`
(default `/data/crt`) as root with mode 755, makes `DIR`, `DIR/bin` and
`DIR/home` root-owned 755, and points `/usr/local/bin/crt` at the copy,
replacing an older copied `crt` there. It refuses unless run as root, and
refuses a `DIR` whose parent directories are not owned by root or are writable
by group or other. Running it again reinstalls only if the script changed.

`crt setup [--prefix DIR] [user...]` delegates a cgroup to each user (see
[Setup](#setup)) and, when `DIR` exists, creates `DIR/home/<user>` owned by
that user with mode 700. With no user it sets up the `sudo` caller. The user's
home directory comes from the passwd database, so a service account such as
`s-ci` with home `/data/ci` works like anyone else. Setup warns when a user's
`CRT_HOME` would sit inside their own home, since hardened runs refuse that.

A non-default `--prefix` is not searched when resolving `CRT_HOME`; those
users set `CRT_HOME=DIR/home/<user>` themselves.

A single-user machine can skip the layout: `cp crt /usr/local/bin/crt` still
works, with `CRT_HOME` at `/home/crt`.

### crt doctor

`crt doctor` checks the current user and exits 1 if anything blocks hardened
runs:

- the resolved `CRT_HOME` and where it came from;
- `CRT_HOME` is owned by you and not writable by group or other (or, if it does
  not exist yet, that its parent is writable);
- `CRT_HOME` is outside `$HOME`, `/tmp` and every config `mount` source;
- unprivileged user namespaces work (`unshare --user --map-root-user`).

It also probes memory limits: a delegated `/sys/fs/cgroup/user-<uid>` with the
memory controller, where you can create a child cgroup, set `memory.max` and
move a process in. A failure there is a warning, since hardened mode does not
need limits; `crt doctor --limits` makes it an error, for callers such as an
eval harness that must not run without them.

## Usage

```
crt create <name>                Bootstrap Void Linux rootfs (xbps)
crt create <name> <image>        Pull rootfs from OCI registry
crt enter  <name>                Interactive shell
crt run [options] <name> <cmd>   Run command (flags override config; see below)
crt list                         List rootfs environments
crt rm     <name>                Remove rootfs
crt export <name> <binary>       Create host wrapper script for a binary
crt install [--prefix DIR]       Install to DIR/bin/crt (root; default /data/crt)
crt setup [--prefix DIR] [user…] Delegate cgroups, make DIR/home/<user> (root)
crt doctor [--limits]            Check readiness for hardened runs
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
sudo crt setup                # the sudo caller
sudo crt setup john s-ci      # named users
```

For each user this:
1. Creates `/sys/fs/cgroup/user-$UID/` and delegates memory+cpu control to that user
2. Creates `/data/crt/home/<user>` (owner the user, mode 700) when `/data/crt` exists
3. On runit systems: adds the user to `/etc/crt-users` and installs `/etc/sv/crt-cgroup/`, which redoes the delegation on every boot

Every user is looked up before anything changes, so an unknown name leaves the
host untouched. `crt doctor --limits`, run as the user, checks the result.

If `crt setup` hasn't been run, `crt run -m 512M ...` warns and continues without limits.

**Supported init systems:** runit (Void Linux). Other init systems receive manual startup instructions from `crt setup`.

## Creating environments

**Void Linux (default, no image required):**

```sh
crt create myenv
```

Uses `xbps-install -S` to sync the Void repository index and bootstrap
`base-minimal` into a new rootfs directory. The host's repo signing keys
(`/var/db/xbps/keys/*.plist`, shipped by the `xbps` package) are copied into the
rootfs first so the non-interactive install can verify packages; if the host has
no such keys, `crt create` fails with a clear message — install `xbps` or
bootstrap from an OCI image instead. Set `XBPS_KEYS_DIR` to override the key
source. `xbps-install` runs with stdin from `/dev/null`, so a repository signed
by a key the host doesn't already trust fails the create instead of prompting.

**From an OCI registry:**

```sh
crt create ubuntu ubuntu:22.04
crt create alpine alpine:3.19
crt create myapp ghcr.io/user/myapp:latest
crt create staging quay.io/org/service:v2.1
```

Supported registries: Docker Hub, ghcr.io, quay.io, and any registry implementing the OCI Distribution Spec. Public images only (no credential support). Multi-arch image indexes are handled — the layer matching the host architecture is selected automatically. Every layer blob is checked against its manifest's sha256 digest, both after download and before a cached copy is reused; a mismatch aborts the create (download) or refetches (cache). Each layer is also checked before it is applied: a member or hardlink target that is absolute, contains `..`, or runs through a symlink (from this layer or a lower one), or a whiteout that would reach outside the rootfs, aborts the create. Member names are read exactly from `tar -t` (never split out of `tar -tv` text, where a name containing ` -> ` or ` link to ` is ambiguous), under a UTF-8 locale so non-ASCII names extract; a name tar still has to escape is refused.

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

Each environment's config is stored **outside** the rootfs, at
`$CRT_HOME/.config/<name>`, so a container can neither read nor rewrite the
config that governs its own — or a later — run. (A legacy config found inside a
rootfs is migrated out, by moving it, the first time that rootfs is run.) The
directives:

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

The file is copied verbatim to `$CRT_HOME/.config/myenv` and used as the source of truth for subsequent `crt run` invocations. Edit it there to change defaults.

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
| `CRT_HOME` | see below | Where rootfs directories are stored |
| `CRT_BIN` | `$CRT_HOME/bin` under `/data/crt`, else `/home/crt/bin` | Where exported wrapper scripts are placed |
| `VOID_REPO` | `https://repo-default.voidlinux.org/current` | xbps repository for Void bootstrap |

`CRT_HOME` is resolved in this order:

1. `$CRT_HOME`, if set and non-empty;
2. `/data/crt/home/<user>`, if that directory exists (`<user>` is `id -un`);
3. `/home/crt`.

Existing setups keep working: a user with no `/data/crt/home/<user>` gets
`/home/crt` as before. `crt doctor` prints the result.

## Runtime dependencies

| Operation | Requires |
|---|---|
| `crt create <name>` (Void) | `xbps-install`, plus the host's repo keys in `/var/db/xbps/keys/` |
| `crt create <name> <image>` (OCI) | `curl`, `jq`, `tar` |
| `crt run` / `crt enter` | `unshare`, `pivot_root`, `chroot` (util-linux) |
| `crt run` (hardened) | also `setpriv`, `findmnt` (util-linux) and `realpath` (coreutils), inside the rootfs |
| `crt install` / `crt setup` | root or `sudo`; `getent` for setup |
| `crt doctor` | `unshare`; cgroup v2 for the limits probe |

`unshare`, `pivot_root`, `chroot`, `setpriv`, and `findmnt` are in `util-linux`, present on any Linux system. In hardened mode `setpriv`, `findmnt`, and `realpath` must exist **inside the rootfs** (they run after `pivot_root`); a Void `base-minimal` or the `-v /usr:/usr:ro` used for the eval sandbox provides them. `curl` and `jq` are only needed for OCI pulls. Read-only bind verification and `--tmp private` use kernel features present on any modern (5.x) kernel.

User namespace support must be enabled on the host kernel (`/proc/sys/kernel/unprivileged_userns_clone` = 1 on some distros).

## Storage layout

Each environment is a plain directory under `CRT_HOME` (`/data/crt/home/<user>`
under the install layout, `/home/crt` otherwise):

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
  .config/       ← per-rootfs stored config (outside every rootfs)
    ubuntu
    myenv
  .state/        ← pristine markers (<name>.pristine), written by crt create
  .cache/
    layers/      ← OCI layer blobs, keyed by digest
```

`CRT_HOME` must live outside `$HOME` and `/tmp` (as `/data/crt/home/<user>`
and `/home/crt` do) for hardened runs; see [Hardened mode](#hardened-mode).

Rootfs directories are self-contained; when moving or archiving one, take its
`.config/<name>` entry with it. A moved or copied rootfs is not pristine (its
marker records the original directory), so recreate it before using it
hardened.

OCI layers are cached in `.cache/layers/` and reused across environments. There is no automatic eviction — run `rm -rf $CRT_HOME/.cache` to clear.

## Testing

```sh
bash test/test-crt.sh         # mock-level: parsing and generated calls, no root
bash test/test-isolation.sh   # real namespaces; skips if userns is unavailable
```

`test/test-crt.sh` uses PATH-based mocks (`test/mocks/`) that shadow system commands:

| Mock | Replaces | What it does |
|---|---|---|
| `unshare` | util-linux | Logs its args (when `CRT_MOCK_LOG` is set), strips namespace flags, runs the inner script on the host; fails when `CRT_MOCK_UNSHARE_FAIL` is set |
| `pivot_root` | util-linux | Always fails, so in test mode `cmd_run` falls back to `chroot` (no real mount namespace under test) |
| `chroot` | util-linux | Drops the rootfs arg, runs the command on the host filesystem |
| `mount` | util-linux | Logs its args (when `CRT_MOCK_LOG` is set), then no-op |
| `curl` | curl | Returns canned token/manifest JSON and the fixture layer `test/fixtures/layer.tar.gz` (whose sha256 is the manifest digest); can log blob fetches, serve a tampered blob, or serve an image built from crafted layers (`CRT_MOCK_LAYERS`, made with `test/mklayer.py`) |
| `xbps-install` | xbps | Logs its args and stdin target (when `CRT_MOCK_LOG` is set), then creates a minimal `bin/sh` skeleton in the rootfs |
| `chown` | coreutils | Logs its args (when `CRT_MOCK_LOG` is set), then no-op (the tests are not root) |
| `getent` | libc | `getent passwd NAME` reads `CRT_MOCK_PASSWD` when set; otherwise the real `getent` |
| `sv` | runit | Logs its args (when `CRT_MOCK_LOG` is set), never touches the host's runit |

`test/test-crt.sh` sets `CRT_TEST_MODE` to its `test/mocks` directory. crt
enables test mode only when `CRT_TEST_MODE` resolves to this repository's own
`test/mocks` (found from the script's real path, carrying `.crt-mocks`): it
takes `unshare` from the mocks, lets `cmd_run` fall back to `chroot`, and skips
read-only verification when the mock `pivot_root` fails. Any other value does
nothing. Test mode also honors `CRT_TEST_SYSROOT`, a directory prefixed to
`/data/crt`, `/usr/local/bin`, `/sys/fs/cgroup`, `/etc` and `/var/service`,
and `CRT_TEST_EUID`, which stands in for the effective uid, so `install`,
`setup` and `doctor` run against a fake host. The suite keeps `CRT_HOME` under `/var/tmp`, and a `crt_run` helper
re-marks the mock rootfs pristine before each run (standing in for `crt
create`). This lets the full `cmd_create` and `cmd_run` code paths run without
root, namespaces, network, or xbps. 197 tests cover `parse_memory`,
`read_config` (including the
`net`/`home`/`tmp`/`env-clean`/`root`/`packages`/`keep-fd` directives),
`write_config`, `parse_image_ref`, all three `create` dispatch paths (with the
`xbps-install -S` / key-copy / `/dev/null`-stdin path), OCI digest checks on
download and cache reuse, OCI layer containment against crafted layers
(`..`/absolute members, escaping whiteouts and hardlinks, paths through
same-layer and lower-layer symlinks, member names containing ` -> ` or
` link to `; plus non-ASCII names and PAX sub-second mtimes that must still
extract; these need python3), hardened binds of
`CRT_HOME`/`.config`/`.state`, `run` flag and config merging, the generated
`unshare`/`mount` calls for each isolation flag, clean-env behavior,
`--keep-fd`/fd closing and the `NODE_CHANNEL_FD` guards, the test-mode switch,
immunity to caller-exported shell functions, name validation and alias
refusal, the pristine marker (written by create, required by hardened runs,
removed by writable runs, identity-keyed), `CRT_HOME` placement, the
out-of-rootfs config and safe legacy migration, a symlinked `CRT_HOME`,
`list`, `rm`, `export`, the `CRT_HOME` resolution order, `install` (root
check, owner and mode, the link, idempotence, unsafe prefixes), `setup`
(per-user `CRT_HOME` dirs for several users, a service account, `SUDO_USER`,
the home-overlap warning, runit registration, refusals), and `doctor` (each
check and its exit code).

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
rootfs are not followed. It also checks the out-of-rootfs config is unreachable
to the container, and that hardened runs are refused on a rootfs previously run
writable (the poisoned-rootfs / planted-`umount`/`setpriv` defense) or carrying
legacy in-rootfs config, and that a hardened run binding `CRT_HOME` (rw, ro,
or through an ancestor) is refused before anything runs. Its `CRT_HOME` is
under `/var/tmp`. 39 checks.

## Limitations

- No private registry authentication
- Resource limits (`memory`/`cpus`) require one-time root setup — run `sudo crt setup` (see [Setup](#setup)). Moving a process into `user-<uid>` also needs write access to the common ancestor cgroup's `cgroup.procs`, so limits apply only when `crt` starts from a process already inside `user-<uid>`; `crt doctor --limits` tests this
- `--net none` isolates the network but provides no NAT/bridge, so the container has loopback only (no outbound access)
- **Default mode is not a sandbox.** A default run has your authority over the
  host and can modify any rootfs, config or marker under `CRT_HOME`. Never run
  untrusted code in default mode; see [Trust model](#trust-model).
- **The rootfs is trusted in hardened mode.** After `pivot_root`, crt runs the
  rootfs's own `umount` and `setpriv` while still privileged, so a modified
  rootfs could defeat isolation. crt guards this with the pristine marker and a
  read-only root, but it does not otherwise verify the rootfs contents. Build
  the rootfs from a trusted source (`crt create`, or bind the host `/usr`
  read-only) and only ever run it hardened.
- **Stale pristine marker after manual changes.** Renaming a rootfs away,
  running it writable under the new name and renaming it back, or `rm -rf` and
  `mkdir` of a rootfs that reuses the old inode, leaves a marker that matches a
  tree `crt create` did not write. Recreate with `crt rm` then `crt create`.
- **Hardlinked legacy config.** A legacy in-rootfs `config` that is a hardlink
  to a file outside `CRT_HOME` is migrated as a hardlink. The rootfs becomes
  non-pristine, so this affects only default runs.
- **The invoking environment is trusted.** crt drops shell functions exported
  by its caller and takes `unshare` from fixed paths, but exported functions
  named like the bash builtins it uses for that (`compgen`, `unset`, `builtin`,
  `command`, `declare`) are out of scope. Only the environment that launches
  crt can set them, and that environment can already run anything as you.
