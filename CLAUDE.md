# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

`crt` is a single-file Bash script — a minimal chroot manager that creates and runs isolated rootfs environments using Linux namespace primitives. No Docker, no podman. The entire tool is in one file: `crt`.

## Architecture

The script follows a simple command-dispatch pattern: each subcommand (`create`, `enter`, `run`, `list`, `rm`, `export`) maps to a `cmd_*` function. The main dispatch is a `case` statement at the bottom of the file.

### Key design decisions

**`cmd_run`** uses `unshare --user --map-root-user --mount --pid --uts --ipc [--net] -f` for rootless isolation. The inner setup script (bind mounts, `/proc`, `/sys`, etc.) runs inside the unshare'd namespace as a single-quoted bash `-c` string. All data crosses the `exec unshare` boundary as positional arguments to avoid shell injection. It enters the rootfs with `pivot_root` and detaches the old root (so in-namespace root cannot escape back to the host filesystem, unlike plain `chroot`); when `pivot_root` fails — as under the test mocks, where there is no real mount namespace — it falls back to `chroot`. The final command is started via a POSIX-sh payload so it works with a `dash` `/bin/sh` in the rootfs; the caller's open file descriptors (>2) are left intact so an inherited IPC fd survives.

Isolation options are both `crt run` flags and config directives, flags overriding config: `--net none`/`net none`, `--no-home`/`home no`, `--tmp private`/`tmp private`, `-v h:c:ro`/`mount h:c:ro`, `--clean-env`/`env-clean yes`, `--ro-root`/`root ro`. `--clean-env` resolves `-e` entries in the parent (where the caller's environment is visible), then the payload uses `env -i` with a minimal `PATH`/`HOME`. Read-only binds are remounted `ro` (recursively when supported) and verified against `/proc/self/mountinfo`, failing closed. Flag parsing is a manual `while`/`case` loop (short `-v -e -m -c` plus long forms), replacing the old `getopts`.

**`cmd_create`** supports three forms:
- No second arg → Void Linux bootstrap via `xbps-install`
- Second arg is an existing file → read as a config file
- Second arg is a string → treat as an OCI image reference

After creation, a config file is always written to `$CRT_HOME/<name>/config`.

**OCI image pull** (`_create_oci`, `oci_token`, `oci_manifest`, `oci_unpack`) is pure shell using `curl` + `jq` + `tar`. Supports Docker Hub, ghcr.io, quay.io, and any OCI Distribution Spec registry. Multi-arch image indexes are handled by selecting the layer matching `uname -m`. Layers are cached at `$CRT_HOME/.cache/layers/` keyed by digest.

**Config files** (`read_config`, `write_config`) use a line-oriented format with directives: `image`, `packages`, `mount`, `env`, `memory`, `cpus`, `net`, `home`, `tmp`, `env-clean`, `root`. `read_config` populates variables in the caller's scope (bash dynamic scoping) — callers must declare the matching `config_*` locals (`config_image`, `config_packages`, `config_mounts`, `config_envs`, `config_memory`, `config_cpus`, `config_net`, `config_home`, `config_tmp`, `config_envclean`, `config_root`) before calling. `packages` is applied only when creating a Void rootfs from a config file (installed with xbps after `base-minimal`).

**Cgroup v2** (`apply_cgroup`) applies memory and CPU limits before `exec unshare`. Requires cgroup v2 with user delegation; degrades gracefully with a warning if unavailable.

## Environment Variables

- `CRT_HOME` — where rootfs directories live (default: `/home/crt`)
- `CRT_BIN` — where exported wrapper scripts are placed (default: `/home/crt/bin`)
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

`test/test-crt.sh` uses PATH-based mocks in `test/mocks/` that shadow `unshare`, `pivot_root`, `chroot`, `mount`, `curl`, and `xbps-install`, letting the full create and run code paths execute without root, namespaces, network, or xbps. `unshare` and `mount` log their args to `$CRT_MOCK_LOG` when set, so tests can assert the generated namespace/mount calls; `pivot_root` always fails so `cmd_run` takes its `chroot` fallback.

`test/test-isolation.sh` is a separate real-namespace test: it builds a throwaway rootfs reusing the host `/usr` (bind-mounted read-only) and verifies network/home/tmp/ro-bind/clean-env/inherited-fd isolation. It self-skips when unprivileged user namespaces are unavailable and has no `~/bin` dependency (its own tiny harness, not `test/Test`).
