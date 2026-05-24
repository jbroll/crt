# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

`crt` is a single-file Bash script — a minimal chroot manager that creates and runs isolated rootfs environments using Linux namespace primitives. No Docker, no podman. The entire tool is in one file: `crt`.

## Architecture

The script follows a simple command-dispatch pattern: each subcommand (`create`, `enter`, `run`, `list`, `rm`, `export`) maps to a `cmd_*` function. The main dispatch is a `case` statement at the bottom of the file.

### Key design decisions

**`cmd_run`** uses `unshare --user --map-root-user --mount --pid --uts --ipc -f` + `chroot` for rootless isolation. The inner setup script (bind mounts, `/proc`, `/sys`, etc.) runs inside the unshare'd namespace as a single-quoted bash `-c` string. All data crosses the `exec unshare` boundary as positional arguments to avoid shell injection.

**`cmd_create`** supports three forms:
- No second arg → Void Linux bootstrap via `xbps-install`
- Second arg is an existing file → read as a config file
- Second arg is a string → treat as an OCI image reference

After creation, a config file is always written to `$CRT_HOME/<name>/config`.

**OCI image pull** (`_create_oci`, `oci_token`, `oci_manifest`, `oci_unpack`) is pure shell using `curl` + `jq` + `tar`. Supports Docker Hub, ghcr.io, quay.io, and any OCI Distribution Spec registry. Multi-arch image indexes are handled by selecting the layer matching `uname -m`. Layers are cached at `$CRT_HOME/.cache/layers/` keyed by digest.

**Config files** (`read_config`, `write_config`) use a line-oriented format with directives: `image`, `mount`, `env`, `memory`, `cpus`. `read_config` populates variables in the caller's scope (bash dynamic scoping) — callers must declare `config_image`, `config_mounts`, `config_envs`, `config_memory`, `config_cpus` as locals before calling.

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

Tests use PATH-based mocks in `test/mocks/` that shadow `unshare`, `chroot`, `mount`, `curl`, and `xbps-install`. This lets the full create and run code paths execute without root, namespaces, network, or xbps installed.
