# Minimal Container Runtime Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove the podman dependency from `crt`, replacing it with xbps bootstrap, pure-shell OCI image pull, and `unshare`+`chroot` for container execution.

**Architecture:** All changes are to the single file `crt`. Three OCI helper functions (`parse_image_ref`, `oci_token`, `oci_manifest`, `oci_unpack`) are added before `cmd_create`. `cmd_create` and `cmd_run` are fully rewritten; all other commands are untouched.

**Tech Stack:** bash, xbps-install, curl, jq, tar, unshare, chroot (util-linux)

---

## File Map

| File | Change |
|---|---|
| `crt` | Modify — rewrite `cmd_create`, `cmd_run`; add OCI helpers; update header/help |

No new files. No new directories. Everything stays in the single `crt` script.

---

## Task 1: Add `parse_image_ref`

**Files:**
- Modify: `crt` (add function before `cmd_create`)

This pure-logic function parses an OCI image reference string into three parts: registry, repository, and tag. All other OCI functions depend on its output.

- [ ] **Step 1: Write a quick test script to define expected behavior**

Create `/tmp/test_parse_image_ref.sh`:

```bash
#!/bin/bash
set -e
source /path/to/crt 2>/dev/null || true  # will fail on main dispatch, that's ok

check() {
    local input="$1" exp_reg="$2" exp_repo="$3" exp_tag="$4"
    read -r reg repo tag <<< "$(parse_image_ref "$input")"
    if [ "$reg" = "$exp_reg" ] && [ "$repo" = "$exp_repo" ] && [ "$tag" = "$exp_tag" ]; then
        echo "PASS: $input"
    else
        echo "FAIL: $input"
        echo "  got:      reg=$reg repo=$repo tag=$tag"
        echo "  expected: reg=$exp_reg repo=$exp_repo tag=$exp_tag"
        exit 1
    fi
}

check "ubuntu:22.04"           "registry-1.docker.io" "library/ubuntu"  "22.04"
check "ubuntu"                 "registry-1.docker.io" "library/ubuntu"  "latest"
check "user/image:tag"         "registry-1.docker.io" "user/image"      "tag"
check "ghcr.io/user/img:v1"    "ghcr.io"              "user/img"        "v1"
check "quay.io/org/app:latest" "quay.io"              "org/app"         "latest"
echo "All tests passed."
```

- [ ] **Step 2: Run test to verify it fails (function not yet defined)**

```bash
bash /tmp/test_parse_image_ref.sh 2>&1 | head -5
```

Expected output: error about `parse_image_ref` not found or similar.

- [ ] **Step 3: Add `parse_image_ref` to `crt`, immediately before `cmd_create`**

```bash
parse_image_ref() {
    local input="$1"
    local registry repo tag

    # Extract tag
    if [[ "$input" == *:* ]] && [[ "${input##*:}" != */* ]]; then
        tag="${input##*:}"
        input="${input%:*}"
    else
        tag="latest"
    fi

    # Extract registry (hostname with dot or colon means it's a registry prefix)
    if [[ "$input" == *.io/* || "$input" == *.com/* || "$input" == *:*/* ]]; then
        registry="${input%%/*}"
        repo="${input#*/}"
    elif [[ "$input" == */* ]]; then
        registry="registry-1.docker.io"
        repo="$input"
    else
        registry="registry-1.docker.io"
        repo="library/$input"
    fi

    echo "$registry" "$repo" "$tag"
}
```

- [ ] **Step 4: Run syntax check**

```bash
bash -n crt
```

Expected: no output (success).

- [ ] **Step 5: Run shellcheck**

```bash
shellcheck crt
```

Expected: no errors (warnings about sourcing are OK).

- [ ] **Step 6: Run the test to verify it passes**

```bash
# Temporarily comment out the bottom case statement's exit 1 for sourcing,
# or wrap source in a subshell that ignores the dispatch error:
(source crt 2>/dev/null; bash /tmp/test_parse_image_ref.sh)
```

If sourcing crt is awkward due to the main dispatch, extract just the function:
```bash
bash -c "$(grep -A 30 '^parse_image_ref()' crt); $(cat /tmp/test_parse_image_ref.sh | grep -v source)"
```

Expected: `All tests passed.`

- [ ] **Step 7: Commit**

```bash
git add crt
git commit -m "feat: add parse_image_ref helper for OCI image references"
```

---

## Task 2: Add `oci_token`

**Files:**
- Modify: `crt` (add function after `parse_image_ref`, before `cmd_create`)

Fetches a bearer token from the appropriate registry auth endpoint. Returns the token on stdout.

- [ ] **Step 1: Add `oci_token` to `crt`**

Add immediately after `parse_image_ref`:

```bash
oci_token() {
    local registry="$1"
    local repo="$2"
    local url

    case "$registry" in
        registry-1.docker.io)
            url="https://auth.docker.io/token?service=registry.docker.io&scope=repository:${repo}:pull"
            ;;
        ghcr.io)
            url="https://ghcr.io/token?scope=repository:${repo}:pull"
            ;;
        quay.io)
            url="https://quay.io/v2/auth?service=quay.io&scope=repository:${repo}:pull"
            ;;
        *)
            url="https://${registry}/v2/auth?scope=repository:${repo}:pull"
            ;;
    esac

    curl -fsSL "$url" | jq -r '.token // .access_token'
}
```

- [ ] **Step 2: Run syntax check**

```bash
bash -n crt
```

Expected: no output.

- [ ] **Step 3: Run shellcheck**

```bash
shellcheck crt
```

Expected: no errors.

- [ ] **Step 4: Smoke-test against Docker Hub (requires network)**

```bash
token=$(bash -c "$(grep -A 20 '^oci_token()' crt | head -20)
oci_token registry-1.docker.io library/alpine")
[ -n "$token" ] && echo "PASS: got token (${#token} chars)" || echo "FAIL: empty token"
```

Expected: `PASS: got token (NNN chars)`

- [ ] **Step 5: Commit**

```bash
git add crt
git commit -m "feat: add oci_token helper for registry authentication"
```

---

## Task 3: Add `oci_manifest`

**Files:**
- Modify: `crt` (add function after `oci_token`, before `cmd_create`)

Fetches a manifest for a given image. Handles image indexes (multi-arch) by selecting the entry matching the host architecture.

- [ ] **Step 1: Add `oci_manifest` to `crt`**

Add immediately after `oci_token`:

```bash
oci_manifest() {
    local registry="$1"
    local repo="$2"
    local tag="$3"
    local token="$4"
    local api_base="https://${registry}/v2/${repo}"
    local arch

    case "$(uname -m)" in
        x86_64)  arch="amd64" ;;
        aarch64) arch="arm64" ;;
        armv7l)  arch="arm" ;;
        *)       arch="$(uname -m)" ;;
    esac

    local manifest
    manifest=$(curl -fsSL \
        -H "Authorization: Bearer $token" \
        -H "Accept: application/vnd.docker.distribution.manifest.v2+json" \
        -H "Accept: application/vnd.oci.image.manifest.v1+json" \
        -H "Accept: application/vnd.docker.distribution.manifest.list.v2+json" \
        -H "Accept: application/vnd.oci.image.index.v1+json" \
        "${api_base}/manifests/${tag}")

    # If it's an image index, select the right arch
    local media_type
    media_type=$(echo "$manifest" | jq -r '.mediaType // ""')
    if echo "$media_type" | grep -q "index\|list"; then
        local digest
        digest=$(echo "$manifest" | jq -r \
            --arg arch "$arch" \
            '.manifests[] | select(.platform.architecture == $arch) | .digest' \
            | head -1)
        manifest=$(curl -fsSL \
            -H "Authorization: Bearer $token" \
            -H "Accept: application/vnd.docker.distribution.manifest.v2+json" \
            -H "Accept: application/vnd.oci.image.manifest.v1+json" \
            "${api_base}/manifests/${digest}")
    fi

    echo "$manifest"
}
```

- [ ] **Step 2: Run syntax check**

```bash
bash -n crt
```

Expected: no output.

- [ ] **Step 3: Run shellcheck**

```bash
shellcheck crt
```

Expected: no errors.

- [ ] **Step 4: Commit**

```bash
git add crt
git commit -m "feat: add oci_manifest helper with multi-arch index support"
```

---

## Task 4: Add `oci_unpack`

**Files:**
- Modify: `crt` (add function after `oci_manifest`, before `cmd_create`)

Downloads and unpacks image layers into a rootfs directory. Processes whiteout files per-layer to correctly apply file deletions.

- [ ] **Step 1: Add `oci_unpack` to `crt`**

Add immediately after `oci_manifest`:

```bash
oci_unpack() {
    local registry="$1"
    local repo="$2"
    local token="$3"
    local manifest="$4"
    local rootfs="$5"
    local api_base="https://${registry}/v2/${repo}"

    local layers
    layers=$(echo "$manifest" | jq -r '.layers[].digest')

    local digest
    for digest in $layers; do
        echo "  layer ${digest:7:12}..."
        curl -fsSL \
            -H "Authorization: Bearer $token" \
            "${api_base}/blobs/${digest}" \
            | tar -xf - -C "$rootfs" 2>/dev/null || true

        # Process whiteout files for this layer
        find "$rootfs" -name '.wh.*' | while read -r wh_file; do
            local dir wh_name
            dir=$(dirname "$wh_file")
            wh_name=$(basename "$wh_file")
            if [ "$wh_name" = ".wh..wh..opq" ]; then
                # Opaque whiteout: delete all non-whiteout entries in the directory
                find "$dir" -mindepth 1 -not -name '.wh.*' -delete
            else
                # Regular whiteout: delete the named file/dir
                rm -rf "$dir/${wh_name#.wh.}"
            fi
            rm -f "$wh_file"
        done
    done
}
```

- [ ] **Step 2: Run syntax check**

```bash
bash -n crt
```

Expected: no output.

- [ ] **Step 3: Run shellcheck**

```bash
shellcheck crt
```

Expected: no errors.

- [ ] **Step 4: Commit**

```bash
git add crt
git commit -m "feat: add oci_unpack helper with per-layer whiteout processing"
```

---

## Task 5: Rewrite `cmd_create`

**Files:**
- Modify: `crt` — replace `cmd_create` entirely; add `_create_xbps` and `_create_oci` helpers

- [ ] **Step 1: Replace `cmd_create` and add the two private helpers**

Replace the entire existing `cmd_create` function (lines 17–44 in the original) with:

```bash
_create_xbps() {
    local rootfs="$1"
    local repo="${VOID_REPO:-https://repo-default.voidlinux.org/current}"

    if ! command -v xbps-install >/dev/null 2>&1; then
        echo "Error: xbps-install not found. Install xbps or pass an OCI image name."
        exit 1
    fi

    echo "Bootstrapping Void Linux via xbps..."
    xbps-install -r "$rootfs" --repository="$repo" -y base-minimal
}

_create_oci() {
    local image="$1"
    local rootfs="$2"

    for dep in curl jq tar; do
        if ! command -v "$dep" >/dev/null 2>&1; then
            echo "Error: '$dep' is required for OCI image pull"
            exit 1
        fi
    done

    echo "Pulling OCI image '$image'..."

    local registry repo tag
    read -r registry repo tag <<< "$(parse_image_ref "$image")"

    local token manifest
    token=$(oci_token "$registry" "$repo")
    manifest=$(oci_manifest "$registry" "$repo" "$tag" "$token")
    oci_unpack "$registry" "$repo" "$token" "$manifest" "$rootfs"
}

cmd_create() {
    local name="$1"
    local image="${2:-}"

    if [ -z "$name" ]; then
        echo "Usage: crt create <name> [image]"
        echo "  no image: bootstrap Void Linux via xbps"
        echo "  image:    pull from OCI registry (e.g. ubuntu:22.04, ghcr.io/user/img)"
        exit 1
    fi

    local rootfs="$CRT_HOME/$name"

    if [ -d "$rootfs" ] && [ -f "$rootfs/bin/sh" ]; then
        echo "Chroot '$name' already exists at $rootfs"
        exit 1
    fi

    mkdir -p "$rootfs"

    if [ -z "$image" ]; then
        _create_xbps "$rootfs"
    else
        _create_oci "$image" "$rootfs"
    fi

    echo "Created: $rootfs ($(du -sh "$rootfs" 2>/dev/null | cut -f1))"
}
```

- [ ] **Step 2: Run syntax check**

```bash
bash -n crt
```

Expected: no output.

- [ ] **Step 3: Run shellcheck**

```bash
shellcheck crt
```

Expected: no errors.

- [ ] **Step 4: Integration test — OCI path (requires network + user namespace support)**

```bash
sudo mkdir -p /home/crt
CRT_HOME=/tmp/crt-test ./crt create test-alpine alpine:3.19
ls /tmp/crt-test/test-alpine/bin/sh && echo "PASS: rootfs populated"
rm -rf /tmp/crt-test
```

Expected: `PASS: rootfs populated`

- [ ] **Step 5: Integration test — xbps path (requires xbps-install)**

```bash
CRT_HOME=/tmp/crt-test ./crt create test-void
ls /tmp/crt-test/test-void/bin/sh && echo "PASS: Void rootfs created"
rm -rf /tmp/crt-test
```

Expected: `PASS: Void rootfs created`

- [ ] **Step 6: Commit**

```bash
git add crt
git commit -m "feat: rewrite cmd_create with xbps bootstrap and pure-shell OCI pull"
```

---

## Task 6: Rewrite `cmd_run`

**Files:**
- Modify: `crt` — replace `cmd_run` entirely

Replaces `podman run --rootfs` with `unshare`+`chroot` providing user, mount, pid, uts, and ipc namespace isolation.

- [ ] **Step 1: Replace `cmd_run`**

Replace the entire existing `cmd_run` function (lines 57–93 in the original) with:

```bash
cmd_run() {
    local name="$1"
    shift

    if [ -z "$name" ]; then
        echo "Usage: crt run <name> <command> [args...]"
        exit 1
    fi

    local rootfs="$CRT_HOME/$name"

    if [ ! -d "$rootfs/bin" ]; then
        echo "Error: Chroot '$name' not found"
        echo "Run: crt create $name"
        exit 1
    fi

    [ $# -eq 0 ] && set -- /bin/bash -l

    local workdir
    workdir="$(pwd)"

    # Pass rootfs, HOME, workdir as positional args to avoid quoting issues
    # across the unshare boundary. The single-quoted script receives them as $1 $2 $3.
    exec unshare --user --map-root-user --mount --pid --uts --ipc -f \
        /bin/bash -c '
            rootfs=$1; userhome=$2; workdir=$3; shift 3
            mount -t proc proc "$rootfs/proc"
            mount -t sysfs sysfs "$rootfs/sys"
            mount --bind /dev "$rootfs/dev"
            mount --bind /dev/pts "$rootfs/dev/pts"
            mount --bind /etc/resolv.conf "$rootfs/etc/resolv.conf"
            mkdir -p "$rootfs$userhome"
            mount --bind "$userhome" "$rootfs$userhome"
            mount --bind /tmp "$rootfs/tmp"
            exec chroot "$rootfs" /bin/sh -c \
                "cd \"$workdir\" 2>/dev/null || cd /; exec \"\$@\"" -- "$@"
        ' -- "$rootfs" "$HOME" "$workdir" "$@"
}
```

- [ ] **Step 2: Run syntax check**

```bash
bash -n crt
```

Expected: no output.

- [ ] **Step 3: Run shellcheck**

```bash
shellcheck crt
```

Expected: no errors. (shellcheck may warn about the single-quoted here-string variables; those are intentional — note with `# shellcheck disable=SC2016` above the exec if needed.)

- [ ] **Step 4: Integration test — run a command**

First create a test rootfs (from Task 5's OCI path, or reuse an existing one):

```bash
CRT_HOME=/tmp/crt-test ./crt create test-alpine alpine:3.19
./crt run test-alpine /bin/sh -c "echo hello from container && uname -r"
```

Expected: `hello from container` followed by a kernel version string.

- [ ] **Step 5: Integration test — verify PID isolation**

```bash
CRT_HOME=/tmp/crt-test ./crt run test-alpine /bin/sh -c "ps aux | wc -l"
```

Expected: a small number (2–5 processes), not the full host process list.

- [ ] **Step 6: Integration test — verify DNS works (requires rootfs with resolv.conf)**

```bash
CRT_HOME=/tmp/crt-test ./crt run test-alpine /bin/sh -c "cat /etc/resolv.conf"
```

Expected: host nameserver entries (from bind-mounted `/etc/resolv.conf`).

- [ ] **Step 7: Integration test — verify $HOME is accessible**

```bash
CRT_HOME=/tmp/crt-test ./crt run test-alpine /bin/sh -c "ls $HOME" | head -5
```

Expected: contents of your home directory.

- [ ] **Step 8: Cleanup**

```bash
rm -rf /tmp/crt-test
```

- [ ] **Step 9: Commit**

```bash
git add crt
git commit -m "feat: rewrite cmd_run with unshare+chroot namespace isolation"
```

---

## Task 7: Update header comment and help text

**Files:**
- Modify: `crt` — update top comment and `cmd_help`

- [ ] **Step 1: Update the top comment**

Replace:
```bash
# crt - minimal chroot manager using podman
#
# Usage:
#   crt create <name> [image]       # Create rootfs (default: ubuntu:22.04)
```

With:
```bash
# crt - minimal chroot manager
#
# Usage:
#   crt create <name>               # Bootstrap Void Linux rootfs via xbps
#   crt create <name> [image]       # Pull rootfs from OCI registry (e.g. ubuntu:22.04)
```

- [ ] **Step 2: Update `cmd_help`**

Replace the body of `cmd_help` with:

```bash
cmd_help() {
    cat << 'EOF'
crt - minimal chroot manager

Usage:
  crt create <name>               Bootstrap Void Linux rootfs (xbps)
  crt create <name> [image]       Pull rootfs from OCI registry
  crt enter <name>                Interactive shell
  crt run <name> <cmd> [args...]  Run command in isolated environment
  crt list                        List chroots
  crt rm <name>                   Remove chroot
  crt export <name> <binary>      Create host wrapper for binary

Environment:
  CRT_HOME    Where chroots are stored (default: /home/crt)
  CRT_BIN     Where wrappers are created (default: /home/crt/bin)
  VOID_REPO   Void Linux package repo (default: https://repo-default.voidlinux.org/current)

Runtime deps:
  xbps-install  required for: crt create <name>
  curl jq tar   required for: crt create <name> <image>
  unshare chroot  required for: crt run / crt enter

Examples:
  crt create void-env
  crt create ubuntu ubuntu:22.04
  crt create alpine ghcr.io/library/alpine:3.19
  crt run ubuntu apt install -y perl python3
  crt export ubuntu perl
  crt enter ubuntu
EOF
}
```

- [ ] **Step 3: Run syntax check and shellcheck**

```bash
bash -n crt && shellcheck crt
```

Expected: no output / no errors.

- [ ] **Step 4: Commit**

```bash
git add crt
git commit -m "docs: update header and help text for podman-free runtime"
```

---

## Self-Review

**Spec coverage:**
- xbps bootstrap (`_create_xbps`) → Task 5 ✓
- OCI pull with multi-registry auth (`oci_token`) → Task 2 ✓
- Manifest fetch with image index handling (`oci_manifest`) → Task 3 ✓
- Layer unpack with whiteout processing (`oci_unpack`) → Task 4 ✓
- `parse_image_ref` for Docker Hub / ghcr.io / quay.io → Task 1 ✓
- `unshare`+`chroot` with proc/sys/dev/resolv.conf mounts → Task 6 ✓
- `$HOME` and `/tmp` bind mounts, workdir preservation → Task 6 ✓
- Unchanged commands (list, rm, export, enter) → no tasks needed ✓
- Help/header update → Task 7 ✓

**Placeholder scan:** No TBD/TODO items. All code steps include actual implementation.

**Type consistency:** `parse_image_ref` outputs `registry repo tag` via `echo`; consumed via `read -r registry repo tag <<< "$(parse_image_ref ...)"` in `_create_oci` ✓. `oci_token` returns token on stdout; consumed as `token=$(oci_token ...)` ✓. `oci_manifest` returns JSON on stdout; consumed as `manifest=$(oci_manifest ...)` ✓. `oci_unpack` takes `registry repo token manifest rootfs`; called with those in that order in `_create_oci` ✓.
