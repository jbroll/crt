# Config File, Cgroups, and OCI Layer Cache Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add per-environment config files (image/mount/env/memory/cpus directives), CLI flag overrides on `crt run`, cgroup v2 resource limits, and an OCI layer blob cache to `crt`.

**Architecture:** All changes are to the single file `crt`. Five new helper functions (`parse_memory`, `read_config`, `write_config`, `apply_cgroup`) are added before `cmd_create`. `cmd_create` and `cmd_run` are updated; `oci_unpack` gains a cache check. The layer cache lives at `$CRT_HOME/.cache/layers/`.

**Tech Stack:** bash, cgroup v2 (`/sys/fs/cgroup`), awk (CPU quota math)

---

## File Map

| File | Change |
|---|---|
| `crt` | Add `parse_memory`, `read_config`, `write_config`, `apply_cgroup`; update `cmd_create`, `cmd_run`, `oci_unpack` |
| `README.md` | Document config format, new flags, layer cache, cgroup requirements |

---

## Task 1: Add `parse_memory`

**Files:**
- Modify: `crt` (add before `cmd_create`)

Converts memory strings (`512M`, `2G`, `1024K`) to bytes for writing to `memory.max`.

- [ ] **Step 1: Write an inline test**

```bash
cd /home/john/src/crt
bash -c "
$(grep -A 12 '^parse_memory()' crt 2>/dev/null || echo 'parse_memory() { echo MISSING; }')

check() { [ \"\$(parse_memory \$1)\" = \"\$2\" ] && echo \"PASS: \$1\" || echo \"FAIL: \$1 got \$(parse_memory \$1) want \$2\"; }
check 512M 536870912
check 2G   2147483648
check 1K   1024
check 1024 1024
echo done
"
```

Expected: `FAIL: 512M` (function not defined yet).

- [ ] **Step 2: Add `parse_memory` to `crt` immediately before `_create_xbps`**

```bash
parse_memory() {
    local val="$1"
    local num="${val%[GgMmKk]}"
    case "${val: -1}" in
        G|g) echo $(( num * 1024 * 1024 * 1024 )) ;;
        M|m) echo $(( num * 1024 * 1024 )) ;;
        K|k) echo $(( num * 1024 )) ;;
        *)   echo "$val" ;;
    esac
}
```

- [ ] **Step 3: Run syntax check**

```bash
bash -n /home/john/src/crt/crt && echo "OK"
```

Expected: `OK`

- [ ] **Step 4: Run the test**

```bash
cd /home/john/src/crt
bash -c "
$(grep -A 12 '^parse_memory()' crt)

check() { [ \"\$(parse_memory \$1)\" = \"\$2\" ] && echo \"PASS: \$1\" || echo \"FAIL: \$1 got \$(parse_memory \$1) want \$2\"; }
check 512M 536870912
check 2G   2147483648
check 1K   1024
check 1024 1024
echo done
"
```

Expected: four `PASS` lines then `done`.

- [ ] **Step 5: Commit**

```bash
git add crt && git commit -m "feat: add parse_memory helper for cgroup memory limit conversion"
```

---

## Task 2: Add `read_config`

**Files:**
- Modify: `crt` (add after `parse_memory`, before `_create_xbps`)

Parses a config file into variables in the caller's scope (bash dynamic scoping). The caller must declare these as `local` before calling:
- `config_image` (string)
- `config_mounts` (array)
- `config_envs` (array)
- `config_memory` (string)
- `config_cpus` (string)

- [ ] **Step 1: Write an inline test**

```bash
cd /home/john/src/crt
cat > /tmp/test.conf << 'EOF'
# test config
image ubuntu:22.04
mount /data:/data
mount /logs:/var/log/app
env FOO=bar
env DEBUG=1
memory 512M
cpus 2
EOF

bash -c "
$(grep -A 30 '^read_config()' crt 2>/dev/null || echo 'read_config() { echo MISSING; }')

local config_image='' config_memory='' config_cpus=''
local -a config_mounts=() config_envs=()
read_config /tmp/test.conf
echo \"image=\$config_image\"
echo \"mounts=\${config_mounts[*]}\"
echo \"envs=\${config_envs[*]}\"
echo \"memory=\$config_memory\"
echo \"cpus=\$config_cpus\"
" 2>&1 | head -10
```

Expected: error or MISSING (function not yet defined).

- [ ] **Step 2: Add `read_config` after `parse_memory`**

```bash
read_config() {
    local config_file="$1"
    config_image=""
    config_mounts=()
    config_envs=()
    config_memory=""
    config_cpus=""

    [ -f "$config_file" ] || return 0

    local key val
    while read -r key val; do
        case "$key" in
            '#'*|'') continue ;;
            image)   config_image="$val" ;;
            mount)   config_mounts+=("$val") ;;
            env)     config_envs+=("$val") ;;
            memory)  config_memory="$val" ;;
            cpus)    config_cpus="$val" ;;
        esac
    done < "$config_file"
}
```

- [ ] **Step 3: Run syntax check**

```bash
bash -n /home/john/src/crt/crt && echo "OK"
```

Expected: `OK`

- [ ] **Step 4: Run the test**

```bash
cd /home/john/src/crt
cat > /tmp/test.conf << 'EOF'
# test config
image ubuntu:22.04
mount /data:/data
mount /logs:/var/log/app
env FOO=bar
env DEBUG=1
memory 512M
cpus 2
EOF

bash -c "
$(grep -A 25 '^read_config()' crt)

config_image=''; config_memory=''; config_cpus=''
config_mounts=(); config_envs=()
read_config /tmp/test.conf
[ \"\$config_image\" = 'ubuntu:22.04' ] && echo 'PASS: image' || echo 'FAIL: image'
[ \"\${#config_mounts[@]}\" = '2' ]    && echo 'PASS: mounts' || echo 'FAIL: mounts'
[ \"\${#config_envs[@]}\" = '2' ]      && echo 'PASS: envs'   || echo 'FAIL: envs'
[ \"\$config_memory\" = '512M' ]        && echo 'PASS: memory' || echo 'FAIL: memory'
[ \"\$config_cpus\" = '2' ]             && echo 'PASS: cpus'   || echo 'FAIL: cpus'
"
```

Expected: five `PASS` lines.

- [ ] **Step 5: Commit**

```bash
git add crt && git commit -m "feat: add read_config helper for per-environment config parsing"
```

---

## Task 3: Add `write_config`

**Files:**
- Modify: `crt` (add after `read_config`, before `_create_xbps`)

Writes a minimal config file with just the `image` directive. Used by `cmd_create`. Users add `mount`/`env`/`memory`/`cpus` directives by editing the stored file directly, or by providing an input config file.

- [ ] **Step 1: Add `write_config` after `read_config`**

```bash
write_config() {
    local config_file="$1"
    local image="$2"
    printf 'image %s\n' "$image" > "$config_file"
}
```

- [ ] **Step 2: Run syntax check**

```bash
bash -n /home/john/src/crt/crt && echo "OK"
```

Expected: `OK`

- [ ] **Step 3: Test**

```bash
bash -c "
$(grep -A 4 '^write_config()' /home/john/src/crt/crt)
write_config /tmp/out.conf 'ubuntu:22.04'
cat /tmp/out.conf
"
```

Expected:
```
image ubuntu:22.04
```

- [ ] **Step 4: Commit**

```bash
git add crt && git commit -m "feat: add write_config helper to record image after create"
```

---

## Task 4: Add `apply_cgroup`

**Files:**
- Modify: `crt` (add after `write_config`, before `_create_xbps`)

Sets up cgroup v2 memory and CPU limits. All failures are warnings — the container still runs without limits. The cgroup dir is cleaned up automatically by the kernel once all processes exit.

- [ ] **Step 1: Add `apply_cgroup` after `write_config`**

```bash
apply_cgroup() {
    local memory="$1"
    local cpus="$2"

    [ -z "$memory" ] && [ -z "$cpus" ] && return 0

    if [ ! -f /sys/fs/cgroup/cgroup.controllers ]; then
        echo "Warning: cgroup v2 not available, resource limits not applied" >&2
        return 0
    fi

    local cg="/sys/fs/cgroup/crt-$$"
    if ! mkdir -p "$cg" 2>/dev/null; then
        echo "Warning: cannot create cgroup $cg, resource limits not applied" >&2
        return 0
    fi

    if ! echo $$ > "$cg/cgroup.procs" 2>/dev/null; then
        echo "Warning: cannot join cgroup, resource limits not applied" >&2
        rmdir "$cg" 2>/dev/null
        return 0
    fi

    if [ -n "$memory" ]; then
        local mem_bytes
        mem_bytes=$(parse_memory "$memory")
        echo "$mem_bytes" > "$cg/memory.max" 2>/dev/null || \
            echo "Warning: failed to set memory limit to $memory" >&2
    fi

    if [ -n "$cpus" ]; then
        local quota
        quota=$(awk "BEGIN { printf \"%d\", $cpus * 100000 }")
        echo "$quota 100000" > "$cg/cpu.max" 2>/dev/null || \
            echo "Warning: failed to set CPU limit to $cpus" >&2
    fi
}
```

- [ ] **Step 2: Run syntax check**

```bash
bash -n /home/john/src/crt/crt && echo "OK"
```

Expected: `OK`

- [ ] **Step 3: Run shellcheck**

```bash
shellcheck /home/john/src/crt/crt 2>&1 | grep -v "^$"
```

Expected: no new errors (pre-existing warnings about SC2155/SC2016 are OK).

- [ ] **Step 4: Manual smoke test (if running as a user with cgroup v2 delegation)**

```bash
bash -c "
$(grep -A 5 '^parse_memory()' /home/john/src/crt/crt)
$(grep -A 30 '^apply_cgroup()' /home/john/src/crt/crt)
apply_cgroup 256M 1
ls /sys/fs/cgroup/crt-\$\$ 2>/dev/null && echo 'PASS: cgroup created' || echo 'SKIP: no cgroup delegation'
"
```

Expected: `PASS: cgroup created` or `SKIP`/warning (both are acceptable).

- [ ] **Step 5: Commit**

```bash
git add crt && git commit -m "feat: add apply_cgroup helper for cgroup v2 resource limits"
```

---

## Task 5: Update `cmd_create` with config file support

**Files:**
- Modify: `crt` — update `cmd_create` only

The second argument is now disambiguated: if it's an existing file, treat it as a config file; otherwise treat it as an image reference (existing behavior). Always write a stored config after creation.

- [ ] **Step 1: Replace `cmd_create` with the following**

```bash
cmd_create() {
    local name="$1"
    local arg="${2:-}"

    if [ -z "$name" ]; then
        echo "Usage: crt create <name> [image|config-file]"
        echo "  no second arg:   bootstrap Void Linux via xbps"
        echo "  image reference: pull from OCI registry (e.g. ubuntu:22.04)"
        echo "  config file:     read directives from file (image, mount, env, memory, cpus)"
        exit 1
    fi

    local rootfs="$CRT_HOME/$name"

    if [ -d "$rootfs" ] && [ -f "$rootfs/bin/sh" ]; then
        echo "Chroot '$name' already exists at $rootfs"
        exit 1
    fi

    mkdir -p "$rootfs"
    trap 'rm -rf "$rootfs"' ERR

    local stored_config="$CRT_HOME/$name/config"

    if [ -z "$arg" ]; then
        _create_xbps "$rootfs"
        write_config "$stored_config" "void"
    elif [ -f "$arg" ]; then
        local config_image="" config_memory="" config_cpus=""
        local -a config_mounts=() config_envs=()
        read_config "$arg"
        if [ -z "$config_image" ] || [ "$config_image" = "void" ]; then
            _create_xbps "$rootfs"
        else
            _create_oci "$config_image" "$rootfs"
        fi
        cp "$arg" "$stored_config"
    else
        _create_oci "$arg" "$rootfs"
        write_config "$stored_config" "$arg"
    fi

    trap - ERR
    echo "Created: $rootfs ($(du -sh "$rootfs" 2>/dev/null | cut -f1))"
}
```

- [ ] **Step 2: Run syntax check**

```bash
bash -n /home/john/src/crt/crt && echo "OK"
```

Expected: `OK`

- [ ] **Step 3: Run shellcheck**

```bash
shellcheck /home/john/src/crt/crt 2>&1 | grep -v "^$"
```

Expected: no new errors.

- [ ] **Step 4: Integration test — config file form**

```bash
cat > /tmp/test-create.conf << 'EOF'
image alpine:3.19
mount /tmp:/tmp/host
env TEST=hello
EOF

CRT_HOME=/tmp/crt-test ./crt create test-from-file /tmp/test-create.conf
cat /tmp/crt-test/test-from-file/config
rm -rf /tmp/crt-test
```

Expected: rootfs created, `/tmp/crt-test/test-from-file/config` matches the input file.

- [ ] **Step 5: Integration test — inline image form**

```bash
CRT_HOME=/tmp/crt-test ./crt create test-inline alpine:3.19
cat /tmp/crt-test/test-inline/config
rm -rf /tmp/crt-test
```

Expected: config contains `image alpine:3.19`.

- [ ] **Step 6: Commit**

```bash
git add crt && git commit -m "feat: update cmd_create to read config files and write stored config"
```

---

## Task 6: Update `cmd_run` with flags, config loading, and cgroups

**Files:**
- Modify: `crt` — update `cmd_run` only

Adds `getopts` flag parsing (`-v`, `-e`, `-m`, `-c`), reads stored config, merges flags, applies env vars and cgroup limits, and passes additional mounts into the unshare script via positional args.

- [ ] **Step 1: Replace `cmd_run` with the following**

```bash
cmd_run() {
    OPTIND=1
    local opt
    local -a flag_mounts=() flag_envs=()
    local flag_memory="" flag_cpus=""

    while getopts ':v:e:m:c:' opt; do
        case "$opt" in
            v) flag_mounts+=("$OPTARG") ;;
            e) flag_envs+=("$OPTARG") ;;
            m) flag_memory="$OPTARG" ;;
            c) flag_cpus="$OPTARG" ;;
            :) echo "Error: -$OPTARG requires an argument" >&2; exit 1 ;;
            ?) echo "Error: unknown option -$OPTARG" >&2; exit 1 ;;
        esac
    done
    shift $((OPTIND - 1))

    local name="$1"
    shift

    if [ -z "$name" ]; then
        echo "Usage: crt run [-v host:container] [-e KEY=val] [-m SIZE] [-c FLOAT] <name> [cmd...]"
        exit 1
    fi

    local rootfs="$CRT_HOME/$name"

    if [ ! -d "$rootfs/bin" ]; then
        echo "Error: Chroot '$name' not found"
        echo "Run: crt create $name"
        exit 1
    fi

    # Load stored config
    local config_image="" config_memory="" config_cpus=""
    local -a config_mounts=() config_envs=()
    read_config "$CRT_HOME/$name/config"

    # Merge: config first, flags override/extend
    local -a all_mounts=("${config_mounts[@]}" "${flag_mounts[@]}")
    local -a all_envs=("${config_envs[@]}" "${flag_envs[@]}")
    local memory="${flag_memory:-$config_memory}"
    local cpus="${flag_cpus:-$config_cpus}"

    # Apply env vars (inherited through exec unshare automatically)
    local env_spec
    for env_spec in "${all_envs[@]}"; do
        export "${env_spec?}"
    done

    # Apply cgroup limits before exec
    apply_cgroup "$memory" "$cpus"

    [ $# -eq 0 ] && set -- /bin/bash -l

    local workdir
    workdir="$(pwd)"

    # shellcheck disable=SC2016
    exec unshare --user --map-root-user --mount --pid --uts --ipc -f \
        /bin/bash -c '
            rootfs=$1; userhome=$2; workdir=$3; nmounts=$4; shift 4
            mkdir -p "$rootfs/proc" "$rootfs/sys" "$rootfs/dev/pts" "$rootfs/tmp" "$rootfs/etc"
            touch "$rootfs/etc/resolv.conf"
            mount -t proc proc "$rootfs/proc"
            mount -t sysfs sysfs "$rootfs/sys"
            mount --bind /dev "$rootfs/dev"
            mount --bind /dev/pts "$rootfs/dev/pts"
            mount --bind /etc/resolv.conf "$rootfs/etc/resolv.conf"
            mkdir -p "$rootfs$userhome"
            mount --bind "$userhome" "$rootfs$userhome"
            mount --bind /tmp "$rootfs/tmp"
            i=0
            while [ "$i" -lt "$nmounts" ]; do
                spec=$1; shift; i=$((i+1))
                host="${spec%%:*}"; container="${spec#*:}"
                mkdir -p "$rootfs$container"
                mount --bind "$host" "$rootfs$container"
            done
            exec chroot "$rootfs" /bin/sh -c \
                '"'"'cd "$1" 2>/dev/null || cd /; shift; exec "$@"'"'"' -- "$workdir" "$@"
        ' -- "$rootfs" "$HOME" "$workdir" "${#all_mounts[@]}" "${all_mounts[@]}" "$@"
}
```

- [ ] **Step 2: Run syntax check**

```bash
bash -n /home/john/src/crt/crt && echo "OK"
```

Expected: `OK`

- [ ] **Step 3: Run shellcheck**

```bash
shellcheck /home/john/src/crt/crt 2>&1 | grep -v "^$"
```

Expected: no new errors beyond pre-existing SC2016/SC2026/SC2145 in the unshare block (all disabled).

- [ ] **Step 4: Integration test — env var from config**

```bash
cat > /tmp/envtest.conf << 'EOF'
image alpine:3.19
env GREETING=hello
EOF
CRT_HOME=/tmp/crt-test ./crt create envtest /tmp/envtest.conf
./crt run envtest /bin/sh -c 'echo $GREETING'
rm -rf /tmp/crt-test
```

Expected output: `hello`

- [ ] **Step 5: Integration test — -v flag mount**

```bash
mkdir -p /tmp/hostdata && echo "from host" > /tmp/hostdata/file.txt
CRT_HOME=/tmp/crt-test ./crt create mounttest alpine:3.19
./crt run -v /tmp/hostdata:/mnt/data mounttest /bin/sh -c 'cat /mnt/data/file.txt'
rm -rf /tmp/crt-test /tmp/hostdata
```

Expected output: `from host`

- [ ] **Step 6: Integration test — -e flag override**

```bash
cat > /tmp/etest.conf << 'EOF'
image alpine:3.19
env MODE=production
EOF
CRT_HOME=/tmp/crt-test ./crt create etest /tmp/etest.conf
./crt run -e MODE=debug etest /bin/sh -c 'echo $MODE'
rm -rf /tmp/crt-test
```

Expected output: `debug`

- [ ] **Step 7: Commit**

```bash
git add crt && git commit -m "feat: update cmd_run with config loading, flag overrides, and cgroup limits"
```

---

## Task 7: Add OCI layer cache to `oci_unpack`

**Files:**
- Modify: `crt` — update `oci_unpack` only

Cache location: `$CRT_HOME/.cache/layers/`. Each blob is stored as `sha256-<digest>` (colon replaced with dash). On cache hit: pipe file to tar. On miss: `tee` to cache file and tar simultaneously. Partial downloads are cleaned up on failure.

- [ ] **Step 1: Replace the layer download block inside `oci_unpack`**

Find the `for digest in $layers` loop inside `oci_unpack`. Replace the entire loop body with:

```bash
    local cache_dir="$CRT_HOME/.cache/layers"
    mkdir -p "$cache_dir"

    local digest
    for digest in $layers; do
        local blob="$cache_dir/${digest//:/-}"
        echo "  layer ${digest:7:12}..."

        if [ -f "$blob" ]; then
            tar -xzf "$blob" -C "$rootfs" 2>/dev/null || {
                echo "Error: failed to unpack cached layer ${digest:7:12}" >&2
                return 1
            }
        else
            (set -o pipefail; curl -fsSL \
                -H "Authorization: Bearer $token" \
                "${api_base}/blobs/${digest}" \
                | tee "$blob" \
                | tar -xzf - -C "$rootfs" 2>/dev/null) || {
                rm -f "$blob"
                echo "Error: failed to download or unpack layer ${digest:7:12}" >&2
                return 1
            }
        fi

        # Process whiteout files for this layer before moving to the next
        while read -r wh_file; do
            local dir wh_name
            dir=$(dirname "$wh_file")
            wh_name=$(basename "$wh_file")
            if [ "$wh_name" = ".wh..wh..opq" ]; then
                find "$dir" -mindepth 1 -not -name '.wh.*' -delete
            else
                rm -rf "$dir/${wh_name#.wh.}"
            fi
            rm -f "$wh_file"
        done < <(find "$rootfs" -name '.wh.*')
    done
```

- [ ] **Step 2: Run syntax check**

```bash
bash -n /home/john/src/crt/crt && echo "OK"
```

Expected: `OK`

- [ ] **Step 3: Run shellcheck**

```bash
shellcheck /home/john/src/crt/crt 2>&1 | grep -v "^$"
```

Expected: no new errors.

- [ ] **Step 4: Integration test — verify cache is populated on first pull**

```bash
CRT_HOME=/tmp/crt-test ./crt create cache-test alpine:3.19
ls /tmp/crt-test/.cache/layers/ | wc -l
```

Expected: one or more files (one per layer in the alpine image).

- [ ] **Step 5: Integration test — verify cache is used on second pull (faster, no network)**

```bash
# Second create reuses cached layers
time CRT_HOME=/tmp/crt-test ./crt create cache-test2 alpine:3.19
rm -rf /tmp/crt-test
```

Expected: second create completes faster (no curl output for layers); no "downloading" delay.

- [ ] **Step 6: Commit**

```bash
git add crt && git commit -m "feat: add OCI layer blob cache to oci_unpack"
```

---

## Task 8: Update README

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Add config file section after the "Usage" section**

Add after the existing usage table:

```markdown
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
```

- [ ] **Step 2: Update the `crt run` entry in the usage table and add flags section**

Update the run line:
```
crt run [-v h:c] [-e K=v] [-m SIZE] [-c N] <name> <cmd>  Run command (flags override config)
```

Add a flags section:

```markdown
### `crt run` flags

Flags add to or override the stored config for a single invocation:

| Flag | Description |
|---|---|
| `-v /host:/container` | Additional bind mount |
| `-e KEY=val` | Additional or override env var |
| `-m SIZE` | Memory limit override (e.g. `256M`) |
| `-c FLOAT` | CPU limit override (e.g. `1.5`) |
```

- [ ] **Step 3: Add OCI layer cache and cgroup notes to the Limitations section**

Replace the two limitation bullets:
```markdown
- No OCI layer caching (layers are re-downloaded per `create`)
```
with:
```markdown
- OCI layers are cached at `$CRT_HOME/.cache/layers/` (no automatic eviction — `rm -rf $CRT_HOME/.cache` to clear)
```

Replace:
```markdown
- No resource limits (cgroups not wired up)
```
with:
```markdown
- Resource limits (`memory`/`cpus`) require cgroup v2 with user delegation; degrade gracefully with a warning if unavailable
```

- [ ] **Step 4: Commit**

```bash
git add README.md && git commit -m "docs: document config file format, run flags, layer cache, and cgroup limits"
```

---

## Self-Review

**Spec coverage:**
- Config file format (image/mount/env/memory/cpus) → Tasks 2, 3 ✓
- `crt create` file detection and config writing → Task 5 ✓
- `crt run` getopts flags (-v/-e/-m/-c) → Task 6 ✓
- `crt run` reads stored config → Task 6 ✓
- Env vars applied via export before exec → Task 6 ✓
- Mounts passed as positional args through unshare boundary → Task 6 ✓
- Cgroup v2 limits with graceful degradation → Tasks 1, 4, 6 ✓
- OCI layer cache with tee-on-miss, cleanup on failure → Task 7 ✓
- README updated → Task 8 ✓

**Placeholder scan:** All code blocks are complete. No TBD/TODO.

**Type consistency:**
- `read_config` sets: `config_image`, `config_mounts[]`, `config_envs[]`, `config_memory`, `config_cpus` — consumed identically in Task 5 (`cmd_create`) and Task 6 (`cmd_run`) ✓
- `parse_memory` returns bytes as string — consumed in `apply_cgroup` via `echo "$mem_bytes" > memory.max` ✓
- `write_config` takes `(file, image)` — called identically in both create paths in Task 5 ✓
- `apply_cgroup` takes `(memory, cpus)` — called in Task 6 with `"$memory" "$cpus"` ✓
- Layer cache uses `${digest//:/-}` for filename — consistent between write (Task 7 miss path) and read (Task 7 hit path) ✓
