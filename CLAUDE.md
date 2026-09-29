# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

`crt` is a single-file Bash script — a minimal chroot manager that creates and runs isolated rootfs environments using Linux namespace primitives. No Docker, no podman. The entire tool is in one file: `crt`.

## Architecture

The script follows a simple command-dispatch pattern: each subcommand (`create`, `enter`, `run`, `list`, `rm`, `export`, `install`, `setup`, `doctor`, `home`, `cgroup-exec`) maps to a `cmd_*` function. The main dispatch is a `case` statement at the bottom of the file; just before it, test mode is detected (`crt_test_mocks`) and `resolve_crt_home` sets `CRT_HOME`, `CRT_BIN`, `CRT_CONF_DIR` and `CRT_STATE_DIR`.

**Install layout** (`cmd_install`, `cmd_setup`, `cmd_doctor`): `/data/crt` (root, 755) holds `bin/crt` (root, 755; `/usr/local/bin/crt` links to it) and `home/<user>` (each user's `CRT_HOME`, owned by the user, 700). `crt install [--prefix DIR]` copies the running script there atomically and is idempotent; `crt setup [--prefix DIR] [user...]` delegates cgroups and creates `home/<user>` for each user (arguments first, else `SUDO_USER`), looking every user up with `getent passwd` before changing anything, and warns when a user's `CRT_HOME` would be inside their passwd home. Both refuse unless root, reset `PATH` to the trusted path, and refuse a prefix whose ancestors are not root-only (`check_root_only_path`). `crt doctor [--limits]` reports the resolved `CRT_HOME`, its ownership and placement, whether user namespaces work, and probes the memory cgroup; it exits 1 on anything that blocks hardened runs (cgroup problems only with `--limits`). `crt home` prints the resolved `CRT_HOME`.

**cgroup layout**: `user-<uid>` is delegated (owned by the user, `+memory +cpu` in its `subtree_control`) and holds no processes itself (no-internal-processes rule). Callers live in a leaf, `user-<uid>/<leaf>`, which root puts them in with `crt cgroup-exec <user> [--leaf NAME] -- cmd` (it redoes the delegation, joins the leaf, restores the caller's `PATH`, execs cmd as root; cmd drops privileges itself). `apply_cgroup` puts each run in the sibling `user-<uid>/crt-$$`, so the move's common ancestor is the user-owned `user-<uid>`, which the kernel requires. Without the leaf, the ancestor is root's and the join fails.

### Key design decisions

**`cmd_run`** uses `unshare --user --map-root-user --mount --pid --uts --ipc [--net] -f` for rootless isolation. The inner setup script runs inside the unshare'd namespace as a single-quoted bash `-c` string; all data crosses the `exec unshare` boundary as positional arguments to avoid shell injection. It enters the rootfs with `pivot_root`, then unconditionally detaches the old root (`umount -l /oldroot`, no redirect into the new root) and verifies it is gone from `/proc/self/mountinfo`, aborting otherwise. The final command is started via a POSIX-sh payload so it works with a `dash` `/bin/sh`.

**Hardened mode** is on whenever any isolation option is requested (`net none`, `no-home`, `tmp private`, a `:ro` bind, `clean-env`, `ro-root`). Then every setup step fails closed (inner helpers `hreq`/`req`/`crt_die`; `hreq` aborts only when hardened), read-only binds are verified with `findmnt` (fail closed; skipped only under `CRT_TEST_MODE`), and the command is exec'd through `setpriv --no-new-privs --bounding-set=-all --inh-caps=-all --ambient-caps=-all` — uid 0 but empty capability set, so it cannot remount, unmount, or create mounts. Without any isolation option the command keeps root + capabilities so `apt install` etc. still work.

**pivot_root fallback** to `chroot` happens only under `CRT_TEST_MODE` (set by `test/test-crt.sh`, since the mock `pivot_root` always fails); a real `pivot_root` failure aborts.

**`/dev`** is built minimal: `null zero full random urandom tty` bound from the host onto the rootfs disk (a userns-created tmpfs forbids device writes, so `/dev` is not a tmpfs), plus a fresh `devpts` (`newinstance`) and a private tmpfs `/dev/shm`. The host `/dev` is never bind-mounted whole.

**Mount targets** (`-v` container paths, the `$HOME` bind) are canonicalised with `realpath -m` and refused if they resolve outside the rootfs, so a planted symlink cannot redirect a pre-pivot `mkdir`/`mount`. **File descriptors** above stderr are closed before exec except `--keep-fd`/`keep-fd` entries and, when `-e NODE_CHANNEL_FD` is passed, that fd's value.

Isolation options are both `crt run` flags and config directives, flags overriding config: `--net none`/`net none`, `--no-home`/`home no`, `--tmp private`/`tmp private`, `-v h:c:ro`/`mount h:c:ro`, `--clean-env`/`env-clean yes`, `--ro-root`/`root ro`, `--keep-fd N`/`keep-fd N`. `--clean-env` resolves `-e` entries in the parent (where the caller's environment is visible), then the payload uses `env -i` with a minimal `PATH`/`HOME`. Flag parsing is a manual `while`/`case` loop (short `-v -e -m -c` plus long forms), replacing the old `getopts`.

**`cmd_create`** supports three forms:
- No second arg → Void Linux bootstrap via `xbps-install`
- Second arg is an existing file → read as a config file
- Second arg is a string → treat as an OCI image reference

After creation, a config file is always written to `$CRT_HOME/.config/<name>` (outside the rootfs).

**OCI image pull** (`_create_oci`, `oci_token`, `oci_manifest`, `oci_unpack`) is pure shell using `curl` + `jq` + `tar`. Supports Docker Hub, ghcr.io, quay.io, and any OCI Distribution Spec registry. Multi-arch image indexes are handled by selecting the layer matching `uname -m`. Layers are cached at `$CRT_HOME/.cache/layers/` keyed by digest.

**Config files** (`read_config`, `write_config`) use a line-oriented format with directives: `image`, `packages`, `mount`, `env`, `memory`, `cpus`, `net`, `home`, `tmp`, `env-clean`, `root`, `keep-fd`. `read_config` populates variables in the caller's scope (bash dynamic scoping) — callers must declare the matching `config_*` locals (`config_image`, `config_packages`, `config_mounts`, `config_envs`, `config_memory`, `config_cpus`, `config_net`, `config_home`, `config_tmp`, `config_envclean`, `config_root`, `config_keepfds`) before calling. `packages` is applied only when creating a Void rootfs from a config file (installed with xbps after `base-minimal`).

**Cgroup v2** (`apply_cgroup`) applies memory and CPU limits before `exec unshare`. Requires cgroup v2 with user delegation; degrades gracefully with a warning if unavailable.

## Environment Variables

- `CRT_HOME` — where rootfs directories live: `$CRT_HOME` if set, else `/data/crt/home/$(id -un)` if it exists, else `/home/crt`
- `CRT_BIN` — where exported wrapper scripts are placed (default: `$CRT_HOME/bin` under the `/data/crt` layout, else `/home/crt/bin`)
- `VOID_REPO` — xbps repository URL for Void bootstrap

## Running / Testing

No build step.

```bash
# Verify script syntax
bash -n crt

# Run with ShellCheck if available
shellcheck crt

# Run the test suite
bash test/test-crt.sh
```

`test/test-crt.sh` (210 tests) uses PATH-based mocks in `test/mocks/` that shadow `unshare`, `pivot_root`, `chroot`, `mount`, `curl`, `xbps-install`, `chown`, `getent`, and `sv`, letting the full create, run, install, setup and doctor code paths execute without root, namespaces, network, or xbps. It sets `CRT_TEST_MODE` to its own `test/mocks` directory; crt enables test mode only for that exact directory (carrying `.crt-mocks`), and then lets `cmd_run` fall back to `chroot` and skip read-only verification, and honors `CRT_TEST_SYSROOT` (a fake `/` for `/data/crt`, `/usr/local/bin`, `/sys/fs/cgroup`, `/etc`, `/var/service`) and `CRT_TEST_EUID` (fake root check). Real runs never set it. `unshare`, `mount`, `chown` and `sv` log their args to `$CRT_MOCK_LOG` when set, so tests can assert the generated calls; `getent passwd` reads `$CRT_MOCK_PASSWD`.

`test/test-cgroup.sh` (5 checks, `sudo bash test/test-cgroup.sh [user]`) exercises `cgroup-exec` and `doctor --limits` against the real cgroup tree for a non-root user; it skips unless root.

`test/test-isolation.sh` (39 checks) is a separate real-namespace test: it builds a throwaway rootfs reusing the host `/usr` (bind-mounted read-only) and, mostly from one run with the full flag set, verifies old-root detachment, the capless lockdown (remount/umount/new-mount all blocked), home/tmp hiding, the minimal `/dev`, ro-bind enforcement, clean env, fd keep/close, `NODE_CHANNEL_FD` auto-keep, network isolation, and that a default run is unchanged. It self-skips when unprivileged user namespaces are unavailable and has no `~/bin` dependency (its own tiny harness, not `test/Test`).
