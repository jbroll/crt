# Config File, Cgroups, and OCI Layer Cache — Design Spec

**Date:** 2026-05-24
**Status:** Approved

Two independent subsystems. Implement in order: config+cgroups first, then layer cache.

---

## Subsystem 1: Per-Environment Config File + Cgroups

### Goal

Every environment has a stored config at `$CRT_HOME/<name>/config`. It is both the input spec (`crt create myenv ./myenv.conf`) and the persistent record read by `crt run`.

### Config File Format

Line-oriented. One directive per line. `#` comments and blank lines ignored. Unknown directives silently skipped (forward-compatible).

```
# example config
image  ubuntu:22.04
mount  /data:/data
mount  /logs:/var/log/myapp
env    FOO=bar
env    DEBUG=1
memory 512M
cpus   2
```

| Directive | Cardinality | Description |
|---|---|---|
| `image` | at most once | OCI image reference or `void` for xbps bootstrap |
| `mount` | repeatable | `hostpath:containerpath` bind mount |
| `env` | repeatable | `KEY=val` environment variable |
| `memory` | at most once | Memory limit with M/G suffix (e.g. `512M`, `2G`) |
| `cpus` | at most once | CPU limit as a float (e.g. `2`, `0.5`) |

### `cmd_create` changes

Second argument is disambiguated:

```
crt create myenv                   # xbps bootstrap
crt create myenv ubuntu:22.04      # OCI pull
crt create myenv ./myenv.conf      # read config file
```

Detection: `[ -f "$2" ]` — if the second arg exists as a file, treat it as a config file; otherwise treat it as an image reference (existing behavior).

After creation, `$CRT_HOME/<name>/config` is always written:
- From file form: input config copied verbatim
- From inline image form: config written with `image <ref>`
- From xbps form: config written with `image void`

A new helper `write_config` handles serialization. A new helper `read_config` parses the stored file into local variables/arrays for use in `cmd_run`.

### `cmd_run` changes

**Config loading:** At the start of `cmd_run`, if `$CRT_HOME/<name>/config` exists, parse it:
- Collect `mount` directives into an array
- Collect `env` directives into an array
- Store `memory` and `cpus` values

**CLI flags** (parsed with `getopts` before the name argument):

| Flag | Effect |
|---|---|
| `-v /host:/container` | Additional mount (additive with config) |
| `-e KEY=val` | Additional env var (additive; overrides same key from config) |
| `-m SIZE` | Memory limit (overrides config) |
| `-c FLOAT` | CPU limit (overrides config) |

Flag mounts and envs are appended to the config-sourced arrays. Flag resource limits replace config values.

**Applying config in the unshare script:**

- Mounts: each `mount` directive becomes a `mount --bind $host $rootfs$container` call in the unshare setup block
- Env vars: exported in the outer shell before `exec unshare` so they're inherited automatically
- Resource limits: applied via cgroup v2 before exec (see below)

### Cgroups (cgroup v2)

Applied before `exec unshare` when `memory` or `cpus` is set:

```bash
cg="/sys/fs/cgroup/crt-$$"
mkdir -p "$cg"
echo $$ > "$cg/cgroup.procs"
[ -n "$memory" ] && echo "$mem_bytes" > "$cg/memory.max"
[ -n "$cpus" ]   && echo "$cpu_quota 100000" > "$cg/cpu.max"
```

The cgroup directory is not explicitly cleaned up — the kernel removes it automatically once all processes in the cgroup exit. Since `cmd_run` ends with `exec unshare` (replacing the shell), no EXIT trap is possible or needed.

`memory` value is converted to bytes (parse M/G suffix). `cpus` is converted to a quota: `quota = cpus * 100000` (period = 100000 microseconds).

**Graceful degradation:** If `/sys/fs/cgroup/cgroup.controllers` is absent, or any cgroup write fails, print a warning to stderr and continue without limits. Requires cgroup v2 with delegation to the current user.

---

## Subsystem 2: OCI Layer Cache

### Goal

Avoid re-downloading image layers that have already been fetched. Layers are content-addressed by digest, making them safe to cache globally across all environments.

### Cache location

```
$CRT_HOME/.cache/layers/<digest-with-colon-replaced-by-dash>
```

Example: `sha256:abc123...` → `$CRT_HOME/.cache/layers/sha256-abc123...`

The cache directory is shared across all environments. A layer downloaded for `ubuntu:22.04` is reused when creating another environment that shares a layer.

### Cache strategy: store raw gzipped blobs

On **cache miss**: stream curl output through `tee` to write the blob to cache while simultaneously piping to tar. No extra download pass.

On **cache hit**: pipe the cached blob file directly to tar.

```bash
local cache_dir="$CRT_HOME/.cache/layers"
mkdir -p "$cache_dir"
local blob="$cache_dir/${digest//:/-}"

if [ -f "$blob" ]; then
    tar -xzf "$blob" -C "$rootfs" 2>/dev/null || { ... error ... }
else
    (set -o pipefail
     curl -fsSL -H "Authorization: Bearer $token" "${api_base}/blobs/${digest}" \
         | tee "$blob" \
         | tar -xzf - -C "$rootfs" 2>/dev/null) || {
        rm -f "$blob"   # don't cache partial downloads
        echo "Error: failed to download or unpack layer ${digest:7:12}" >&2
        return 1
    }
fi
```

Partial downloads (curl failure mid-stream) are cleaned up: `blob` is removed on error so a retry starts fresh.

### Cache management

No automatic eviction. Users manage the cache manually:

```sh
rm -rf "$CRT_HOME/.cache"   # clear all cached layers
```

A future `crt cache` subcommand could show size and allow pruning, but is out of scope for this spec.

---

## Summary of changes

| Function | Subsystem | Change |
|---|---|---|
| `cmd_create` | Config | Detect config file arg; write stored config after creation |
| `cmd_run` | Config + Cgroups | Parse flags; load stored config; apply mounts/env/limits |
| `oci_unpack` | Layer cache | Check/populate blob cache before each layer download |
| `read_config` | Config | New helper: parse config file into variables/arrays |
| `write_config` | Config | New helper: serialize image/mounts/env/limits to config file |
| `apply_cgroup` | Cgroups | New helper: set up cgroup v2 limits, graceful fallback |
