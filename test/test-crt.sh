#!/bin/bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CRT="$SCRIPT_DIR/../crt"
MOCKS="$SCRIPT_DIR/mocks"

export PATH="$MOCKS:$PATH"

# The mocks provide no real mount namespace, so the mock pivot_root always fails.
# Test mode lets cmd_run resolve its binaries from the mocks, fall back to chroot,
# and skip ro verification. It is enabled only when CRT_TEST_MODE names a directory
# carrying the mocks' marker file (test/mocks/.crt-mocks) — a bare CRT_TEST_MODE=1
# from a normal caller does nothing. Real runs never point it at a mocks dir.
export CRT_TEST_MODE="$MOCKS"

. "$SCRIPT_DIR/Test"

# Per-test temp home; cleaned on exit
CRT_HOME=$(mktemp -d)
export CRT_HOME
CRT_BIN=$(mktemp -d)
export CRT_BIN
trap 'rm -rf "$CRT_HOME" "$CRT_BIN"' EXIT

# Helper: extract a pure function from crt and run it in a subshell.
# Works for functions whose body contains no nested { } blocks (case/while/if are fine).
run_fn() {
    local fn="$1"; shift
    local body
    body=$(awk "/^${fn}\(\)/,/^\}/" "$CRT")
    bash -c "$body
$fn \"\$@\"" -- "$@"
}

# Helper: create a minimal mock rootfs (what xbps-install mock produces)
make_rootfs() {
    local name="$1"
    local dir="$CRT_HOME/$name"
    mkdir -p "$dir/bin"
    printf '#!/bin/sh\nexec /bin/sh "$@"\n' > "$dir/bin/sh"
    chmod +x "$dir/bin/sh"
}

# ── parse_memory ─────────────────────────────────────────────────────────────
echo "# parse_memory"

Test "512M converts to bytes"
CompareArgs "$(run_fn parse_memory 512M)" "536870912"

Test "2G converts to bytes"
CompareArgs "$(run_fn parse_memory 2G)" "2147483648"

Test "1K converts to bytes"
CompareArgs "$(run_fn parse_memory 1K)" "1024"

Test "bare number passes through"
CompareArgs "$(run_fn parse_memory 1024)" "1024"

Test "lowercase suffix accepted"
CompareArgs "$(run_fn parse_memory 256m)" "268435456"

Test "empty value returns error"
if run_fn parse_memory "" 2>/dev/null; then Fail; else Pass; fi

Test "non-numeric value returns error"
if run_fn parse_memory abc 2>/dev/null; then Fail; else Pass; fi

# ── read_config ──────────────────────────────────────────────────────────────
echo "# read_config"

CONF=$(mktemp)
trap 'rm -f "$CONF"; rm -rf "$CRT_HOME" "$CRT_BIN"' EXIT
cat > "$CONF" << 'EOF'
# example config
image  ubuntu:22.04
mount  /data:/data
mount  /logs:/var/log/app
env    FOO=bar
env    DEBUG=1
memory 512M
cpus   2
EOF

Test "read_config: image"
result=$(bash -c "
$(awk '/^read_config\(\)/,/^\}/' "$CRT")
config_image='' config_memory='' config_cpus=''
config_mounts=() config_envs=()
read_config '$CONF'
echo \"\$config_image\"
")
CompareArgs "$result" "ubuntu:22.04"

# multi-value fields need a richer subshell
Test "read_config: mount count"
result=$(bash -c "
$(awk '/^read_config\(\)/,/^\}/' "$CRT")
config_image='' config_memory='' config_cpus=''
config_mounts=() config_envs=()
read_config '$CONF'
echo \${#config_mounts[@]}
")
CompareArgs "$result" "2"

Test "read_config: env count"
result=$(bash -c "
$(awk '/^read_config\(\)/,/^\}/' "$CRT")
config_image='' config_memory='' config_cpus=''
config_mounts=() config_envs=()
read_config '$CONF'
echo \${#config_envs[@]}
")
CompareArgs "$result" "2"

Test "read_config: memory"
result=$(bash -c "
$(awk '/^read_config\(\)/,/^\}/' "$CRT")
config_image='' config_memory='' config_cpus=''
config_mounts=() config_envs=()
read_config '$CONF'
echo \"\$config_memory\"
")
CompareArgs "$result" "512M"

Test "read_config: cpus"
result=$(bash -c "
$(awk '/^read_config\(\)/,/^\}/' "$CRT")
config_image='' config_memory='' config_cpus=''
config_mounts=() config_envs=()
read_config '$CONF'
echo \"\$config_cpus\"
")
CompareArgs "$result" "2"

Test "read_config: missing file is not an error"
if run_fn read_config /nonexistent/path 2>/dev/null; then Pass; else Fail; fi

Test "read_config: ignores comments and blank lines"
printf '# comment\n\nimage alpine:3.19\n' > "$CONF"
CompareArgs "$(bash -c "
$(awk '/^read_config\(\)/,/^\}/' "$CRT")
config_image='' config_memory='' config_cpus=''
config_mounts=() config_envs=()
read_config '$CONF'
echo \"\$config_image\"
")" "alpine:3.19"

Test "read_config: bare key warns to stderr"
printf 'image\n' > "$CONF"
warn=$(bash -c "
$(awk '/^read_config\(\)/,/^\}/' "$CRT")
config_image='' config_memory='' config_cpus=''
config_mounts=() config_envs=()
read_config '$CONF'
" 2>&1 >/dev/null)
if echo "$warn" | grep -q "Warning"; then Pass; else Fail; fi

# ── write_config ─────────────────────────────────────────────────────────────
echo "# write_config"

Test "write_config creates image directive"
out=$(mktemp)
run_fn write_config "$out" "ubuntu:22.04"
CompareArgs "$(cat "$out")" "image ubuntu:22.04"
rm -f "$out"

Test "write_config overwrites existing file"
out=$(mktemp)
echo "old content" > "$out"
run_fn write_config "$out" "alpine:3.19"
CompareArgs "$(cat "$out")" "image alpine:3.19"
rm -f "$out"

# ── parse_image_ref ───────────────────────────────────────────────────────────
echo "# parse_image_ref"

Test "bare name: docker hub, library prefix, latest tag"
CompareArgs "$(run_fn parse_image_ref ubuntu)" \
    "registry-1.docker.io library/ubuntu latest"

Test "bare name with tag"
CompareArgs "$(run_fn parse_image_ref ubuntu:22.04)" \
    "registry-1.docker.io library/ubuntu 22.04"

Test "user/repo: docker hub, no library prefix"
CompareArgs "$(run_fn parse_image_ref user/repo)" \
    "registry-1.docker.io user/repo latest"

Test "user/repo with tag"
CompareArgs "$(run_fn parse_image_ref user/repo:mytag)" \
    "registry-1.docker.io user/repo mytag"

Test "ghcr.io registry detected by dot"
CompareArgs "$(run_fn parse_image_ref ghcr.io/user/repo:v1)" \
    "ghcr.io user/repo v1"

Test "quay.io multi-segment repo"
CompareArgs "$(run_fn parse_image_ref quay.io/org/service:v2.1)" \
    "quay.io org/service v2.1"

Test "registry with port detected by colon in first segment"
CompareArgs "$(run_fn parse_image_ref localhost:5000/myimage:v1)" \
    "localhost:5000 myimage v1"

Test "no tag defaults to latest"
CompareArgs "$(run_fn parse_image_ref alpine)" \
    "registry-1.docker.io library/alpine latest"

# ── cmd_create ───────────────────────────────────────────────────────────────
echo "# cmd_create"

Test "create with no name prints usage"
out=$("$CRT" create 2>&1 || true)
if echo "$out" | grep -q "Usage"; then Pass; else Fail; fi

Test "create xbps path: rootfs exists"
"$CRT" create voidenv 2>/dev/null
if [ -d "$CRT_HOME/voidenv/bin" ]; then Pass; else Fail; fi

Test "create xbps path: config written with image void"
CompareArgs "$(cat "$CRT_HOME/voidenv/config")" "image void"

Test "create xbps path: duplicate is rejected"
out=$("$CRT" create voidenv 2>&1 || true)
if echo "$out" | grep -q "already exists"; then Pass; else Fail; fi

Test "create OCI path: rootfs exists"
"$CRT" create ocienv alpine:3.19 2>/dev/null
if [ -d "$CRT_HOME/ocienv/bin" ]; then Pass; else Fail; fi

Test "create OCI path: config written with image ref"
CompareArgs "$(cat "$CRT_HOME/ocienv/config")" "image alpine:3.19"

Test "create config-file path: config copied verbatim"
cat > "$CONF" << 'EOF'
image alpine:3.19
env TEST=1
EOF
"$CRT" create fileenv "$CONF" 2>/dev/null
CompareFiles "$CONF" "$CRT_HOME/fileenv/config"

Test "create config-file with image void: uses xbps"
cat > "$CONF" << 'EOF'
image void
env MYVAR=hello
EOF
"$CRT" create voidfromfile "$CONF" 2>/dev/null
if diff "$CRT_HOME/voidfromfile/config" "$CONF" >/dev/null 2>&1 && \
   [ -f "$CRT_HOME/voidfromfile/bin/sh" ]; then Pass; else Fail; fi

Test "create config-file with no image: uses xbps"
printf 'env BARE=yes\n' > "$CONF"
"$CRT" create bareenv "$CONF" 2>/dev/null
if [ -f "$CRT_HOME/bareenv/bin/sh" ]; then Pass; else Fail; fi

# ── cmd_run ──────────────────────────────────────────────────────────────────
echo "# cmd_run"

# Prepare a persistent env for run tests
make_rootfs runenv

Test "run: not-found error goes to stderr"
err=$("$CRT" run noexist echo hi 2>&1 >/dev/null || true)
if echo "$err" | grep -q "not found"; then Pass; else Fail; fi

Test "run: env var from config"
printf 'env GREETING=hello\n' > "$CRT_HOME/runenv/config"
result=$("$CRT" run runenv printenv GREETING 2>/dev/null)
CompareArgs "$result" "hello"

Test "run: -e flag sets env var"
printf '' > "$CRT_HOME/runenv/config"
result=$("$CRT" run -e COLOR=blue runenv printenv COLOR 2>/dev/null)
CompareArgs "$result" "blue"

Test "run: -e flag overrides config env"
printf 'env MODE=production\n' > "$CRT_HOME/runenv/config"
result=$("$CRT" run -e MODE=debug runenv printenv MODE 2>/dev/null)
CompareArgs "$result" "debug"

Test "run: multiple -e flags"
printf '' > "$CRT_HOME/runenv/config"
result=$("$CRT" run -e A=1 -e B=2 runenv sh -c 'echo $A-$B' 2>/dev/null)
CompareArgs "$result" "1-2"

Test "run: command exits with correct code"
"$CRT" run runenv sh -c 'exit 0' 2>/dev/null
rc=$?
CompareArgs "$rc" "0"

Test "run: unknown flag error"
err=$("$CRT" run -z runenv echo hi 2>&1 || true)
if echo "$err" | grep -q "unknown option"; then Pass; else Fail; fi

Test "run: mount spec without colon is rejected"
err=$("$CRT" run -v /nocopath runenv echo hi 2>&1 || true)
if echo "$err" | grep -q "must be host:container"; then Pass; else Fail; fi

Test "run: memory limit warns when cgroup not available"
err=$("$CRT" run -m 512M runenv echo hi 2>&1 >/dev/null || true)
if echo "$err" | grep -q "resource limits not applied"; then Pass; else Fail; fi

# ── cmd_list ─────────────────────────────────────────────────────────────────
echo "# cmd_list"

Test "list shows created environments"
out=$("$CRT" list 2>/dev/null)
if echo "$out" | grep -q "runenv"; then Pass; else Fail; fi

Test "list shows header"
out=$("$CRT" list 2>/dev/null)
if echo "$out" | grep -q "NAME"; then Pass; else Fail; fi

# ── cmd_rm ───────────────────────────────────────────────────────────────────
echo "# cmd_rm"

make_rootfs rmme

Test "rm removes the chroot directory"
"$CRT" rm rmme 2>/dev/null
if [ ! -d "$CRT_HOME/rmme" ]; then Pass; else Fail; fi

Test "rm nonexistent prints error"
out=$("$CRT" rm rmme 2>&1 || true)
if echo "$out" | grep -q "not found\|Error"; then Pass; else Fail; fi

# ── OCI layer cache ──────────────────────────────────────────────────────────
echo "# OCI layer cache"

Test "cache dir created after OCI pull"
"$CRT" create cachetest alpine:3.19 2>/dev/null
if [ -d "$CRT_HOME/.cache/layers" ]; then Pass; else Fail; fi

Test "layer blob written to cache"
blobs=$(ls "$CRT_HOME/.cache/layers/" 2>/dev/null | wc -l)
if [ "$blobs" -gt 0 ]; then Pass; else Fail; fi

Test "second create reuses cache (curl not called for blob)"
# Track curl calls via a counter file
CURL_LOG=$(mktemp)
cat > "$MOCKS/curl" << MOCKEOF
#!/bin/sh
FIXTURES="\$(cd "\$(dirname "\$0")/../fixtures" && pwd)"
url=""
outfile=""
while [ \$# -gt 0 ]; do
    case "\$1" in
        -o) outfile="\$2"; shift 2 ;;
        http*) url="\$1"; shift ;;
        *) shift ;;
    esac
done
case "\$url" in
    *auth*|*token*) printf '{"token":"mock-token"}\n' ;;
    */manifests/*) cat "\$FIXTURES/manifest.json" ;;
    */blobs/*) echo blob >> "$CURL_LOG"; if [ -n "\$outfile" ]; then cp "\$CRT_HOME/.cache/layers/sha256-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" "\$outfile"; else cat "\$CRT_HOME/.cache/layers/sha256-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"; fi ;;
    *) printf 'unhandled: %s\n' "\$url" >&2; exit 1 ;;
esac
MOCKEOF
chmod +x "$MOCKS/curl"
"$CRT" create cachetest2 alpine:3.19 2>/dev/null
blob_fetches=$(wc -l < "$CURL_LOG" 2>/dev/null || echo 0)
rm -f "$CURL_LOG"
# Restore original curl mock
cat > "$MOCKS/curl" << 'MOCKEOF'
#!/bin/sh
FIXTURES="$(cd "$(dirname "$0")/../fixtures" && pwd)"
url=""
outfile=""
while [ $# -gt 0 ]; do
    case "$1" in
        -o) outfile="$2"; shift 2 ;;
        http*) url="$1"; shift ;;
        *) shift ;;
    esac
done
case "$url" in
    *auth*|*token*) printf '{"token":"mock-token"}\n' ;;
    */manifests/*) cat "$FIXTURES/manifest.json" ;;
    */blobs/*)
        tmpdir=$(mktemp -d)
        mkdir -p "$tmpdir/bin"
        printf '#!/bin/sh\nexec /bin/sh "$@"\n' > "$tmpdir/bin/sh"
        chmod +x "$tmpdir/bin/sh"
        if [ -n "$outfile" ]; then
            tar -czf "$outfile" -C "$tmpdir" .
        else
            tar -czf - -C "$tmpdir" .
        fi
        rm -rf "$tmpdir"
        ;;
    *) printf 'mock-curl: unhandled url: %s\n' "$url" >&2; exit 1 ;;
esac
MOCKEOF
chmod +x "$MOCKS/curl"
CompareArgs "$blob_fetches" "0"

# ── cmd_export ────────────────────────────────────────────────────────────────
echo "# cmd_export"

export_env="exportenv"
make_rootfs "$export_env"
mkdir -p "$CRT_HOME/$export_env/usr/bin"
printf '#!/bin/sh\necho hello\n' > "$CRT_HOME/$export_env/usr/bin/mytool"
chmod +x "$CRT_HOME/$export_env/usr/bin/mytool"

Test "export creates wrapper script"
"$CRT" export "$export_env" mytool 2>/dev/null
if [ -f "$CRT_BIN/mytool" ]; then Pass; else Fail; fi

Test "export wrapper is executable"
if [ -x "$CRT_BIN/mytool" ]; then Pass; else Fail; fi

Test "export wrapper contains correct crt run invocation"
if grep -q "run.*$export_env.*/usr/bin/mytool" "$CRT_BIN/mytool"; then Pass; else Fail; fi

Test "export with custom wrapper name"
"$CRT" export "$export_env" mytool myalias 2>/dev/null
if [ -f "$CRT_BIN/myalias" ]; then Pass; else Fail; fi

Test "export missing binary returns error"
err=$("$CRT" export "$export_env" notabinary 2>&1 || true)
if echo "$err" | grep -q "not found"; then Pass; else Fail; fi

Test "export missing chroot returns error"
err=$("$CRT" export noexist mytool 2>&1 || true)
if echo "$err" | grep -q "not found"; then Pass; else Fail; fi

# ── cmd_setup ─────────────────────────────────────────────────────────────────
echo "# cmd_setup"

Test "setup: requires root"
err=$("$CRT" setup 2>&1 || true)
if echo "$err" | grep -q "must run as root"; then Pass; else Fail; fi

Test "setup: without sudo uid requires username arg"
if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
    err=$(sudo env -u SUDO_UID "$CRT" setup 2>&1 || true)
    if echo "$err" | grep -q "sudo crt setup\|crt setup <username>"; then Pass; else Fail; fi
else
    Pass  # skip: no passwordless sudo available
fi

# ── read_config: isolation directives ────────────────────────────────────────
echo "# read_config isolation directives"

read_cfg_field() {
    # $1 = config text, $2 = shell expression printed after read_config
    local text="$1" expr="$2"
    printf '%s' "$text" > "$CONF"
    bash -c "
$(awk '/^read_config\(\)/,/^\}/' "$CRT")
config_image='' config_memory='' config_cpus=''
config_net='' config_home='' config_tmp='' config_envclean='' config_root=''
config_mounts=() config_envs=() config_packages=() config_keepfds=()
read_config '$CONF'
$expr
"
}

Test "read_config: net directive"
CompareArgs "$(read_cfg_field 'net none
' 'echo "$config_net"')" "none"

Test "read_config: home directive"
CompareArgs "$(read_cfg_field 'home no
' 'echo "$config_home"')" "no"

Test "read_config: tmp directive"
CompareArgs "$(read_cfg_field 'tmp private
' 'echo "$config_tmp"')" "private"

Test "read_config: env-clean directive"
CompareArgs "$(read_cfg_field 'env-clean yes
' 'echo "$config_envclean"')" "yes"

Test "read_config: root directive"
CompareArgs "$(read_cfg_field 'root ro
' 'echo "$config_root"')" "ro"

Test "read_config: packages single"
CompareArgs "$(read_cfg_field 'packages nodejs
' 'echo "${#config_packages[@]} ${config_packages[*]}"')" "1 nodejs"

Test "read_config: packages multiple on one line"
CompareArgs "$(read_cfg_field 'packages nodejs python3 git
' 'echo "${#config_packages[@]}"')" "3"

Test "read_config: packages repeatable across lines"
CompareArgs "$(read_cfg_field 'packages nodejs
packages git
' 'echo "${#config_packages[@]}"')" "2"

# ── cmd_run: flag parsing & generated unshare/mount calls ─────────────────────
echo "# cmd_run isolation flags"

make_rootfs isoenv
printf '' > "$CRT_HOME/isoenv/config"

# Run crt with a mock-call log and print the log to stdout.
run_logged() {
    local log
    log=$(mktemp)
    CRT_MOCK_LOG="$log" "$CRT" run "$@" >/dev/null 2>&1
    cat "$log"
    rm -f "$log"
}

Test "run: default does not add --net to unshare"
if run_logged isoenv true | grep -q "^unshare .*--net"; then Fail; else Pass; fi

Test "run: --net none adds --net to unshare"
if run_logged --net none isoenv true | grep -q '^unshare .*--net'; then Pass; else Fail; fi

Test "run: net directive from config adds --net"
printf 'net none\n' > "$CRT_HOME/isoenv/config"
if run_logged isoenv true | grep -q '^unshare .*--net'; then Pass; else Fail; fi
printf '' > "$CRT_HOME/isoenv/config"

Test "run: --net host flag overrides config net none"
printf 'net none\n' > "$CRT_HOME/isoenv/config"
if run_logged --net host isoenv true | grep -q '^unshare .*--net'; then Fail; else Pass; fi
printf '' > "$CRT_HOME/isoenv/config"

Test "run: default binds \$HOME"
if run_logged isoenv true | grep -q -- "^mount --bind $HOME "; then Pass; else Fail; fi

Test "run: --no-home skips the \$HOME bind"
if run_logged --no-home isoenv true | grep -q -- "^mount --bind $HOME "; then Fail; else Pass; fi

Test "run: default binds host /tmp"
if run_logged isoenv true | grep -q -- "^mount --bind /tmp "; then Pass; else Fail; fi

Test "run: --tmp private mounts a tmpfs on /tmp"
log=$(run_logged --tmp private isoenv true)
if echo "$log" | grep -q -- "^mount -t tmpfs tmpfs .*/tmp" && \
   ! echo "$log" | grep -q -- "^mount --bind /tmp "; then Pass; else Fail; fi

Test "run: -v host:container:ro triggers a read-only remount"
tmpsrc=$(mktemp -d)
if run_logged -v "$tmpsrc:/data:ro" isoenv true | grep -q -- "^mount -o remount,bind,ro"; then Pass; else Fail; fi
rmdir "$tmpsrc"

Test "run: rw bind does not trigger a read-only remount"
tmpsrc=$(mktemp -d)
if run_logged -v "$tmpsrc:/data" isoenv true | grep -q -- "^mount -o remount,bind,ro"; then Fail; else Pass; fi
rmdir "$tmpsrc"

Test "run: --ro-root remounts the rootfs read-only"
if run_logged --ro-root isoenv true | grep -q -- "^mount -o remount,bind,ro $CRT_HOME/isoenv$"; then Pass; else Fail; fi

Test "run: invalid --net value is rejected"
err=$("$CRT" run --net bogus isoenv true 2>&1 || true)
if echo "$err" | grep -q "invalid net mode"; then Pass; else Fail; fi

Test "run: invalid --tmp value is rejected"
err=$("$CRT" run --tmp bogus isoenv true 2>&1 || true)
if echo "$err" | grep -q "invalid tmp mode"; then Pass; else Fail; fi

Test "run: long --env flag works"
result=$("$CRT" run --env SHADE=green isoenv printenv SHADE 2>/dev/null)
CompareArgs "$result" "green"

Test "run: long --volume flag is accepted"
tmpsrc=$(mktemp -d)
if run_logged --volume "$tmpsrc:/data" isoenv true | grep -q -- "^mount --rbind $tmpsrc "; then Pass; else Fail; fi
rmdir "$tmpsrc"

# ── cmd_run: clean environment ────────────────────────────────────────────────
echo "# cmd_run clean environment"

Test "run: default inherits caller environment"
result=$(CALLER_VAR=leaked "$CRT" run isoenv printenv CALLER_VAR 2>/dev/null)
CompareArgs "$result" "leaked"

Test "run: --clean-env drops caller environment"
result=$(CALLER_VAR=leaked "$CRT" run --clean-env isoenv sh -c 'echo "${CALLER_VAR:-unset}"' 2>/dev/null)
CompareArgs "$result" "unset"

Test "run: --clean-env sets a minimal HOME"
result=$("$CRT" run --clean-env isoenv sh -c 'echo "$HOME"' 2>/dev/null)
CompareArgs "$result" "/tmp"

Test "run: --clean-env sets a minimal PATH"
result=$("$CRT" run --clean-env isoenv sh -c 'echo "$PATH"' 2>/dev/null)
CompareArgs "$result" "/usr/bin:/bin:/usr/local/bin"

Test "run: -e NAME passes the caller's value through a clean env"
result=$(TOKEN=abc123 "$CRT" run --clean-env -e TOKEN isoenv printenv TOKEN 2>/dev/null)
CompareArgs "$result" "abc123"

Test "run: -e NAME=val still works with a clean env"
result=$("$CRT" run --clean-env -e SHAPE=round isoenv printenv SHAPE 2>/dev/null)
CompareArgs "$result" "round"

Test "run: -e for an unset var warns and is skipped"
warn=$("$CRT" run --clean-env -e DEFINITELY_UNSET_VAR isoenv true 2>&1 >/dev/null || true)
if echo "$warn" | grep -q "not set in environment"; then Pass; else Fail; fi

# ── cmd_run: file descriptors ─────────────────────────────────────────────────
echo "# cmd_run file descriptors"

Test "run: --keep-fd keeps the listed fd open"
result=$("$CRT" run --keep-fd 3 isoenv sh -c 'cat <&3' 3<<<'fd-payload' 2>/dev/null)
CompareArgs "$result" "fd-payload"

Test "run: --keep-fd works with a clean env"
result=$("$CRT" run --clean-env --keep-fd 3 isoenv sh -c 'cat <&3' 3<<<'clean-fd' 2>/dev/null)
CompareArgs "$result" "clean-fd"

Test "run: an unlisted fd is closed"
result=$("$CRT" run isoenv sh -c 'cat <&3 2>/dev/null && echo LEAK || echo closed' 3<<<'secret' 2>/dev/null)
CompareArgs "$result" "closed"

Test "run: -e NODE_CHANNEL_FD keeps that fd open automatically"
result=$(NODE_CHANNEL_FD=3 "$CRT" run --clean-env -e NODE_CHANNEL_FD isoenv sh -c 'cat <&3' 3<<<'ipc-msg' 2>/dev/null)
CompareArgs "$result" "ipc-msg"

Test "run: NODE_CHANNEL_FD naming an unopened fd is not kept (New-4)"
result=$(NODE_CHANNEL_FD=9 "$CRT" run --clean-env -e NODE_CHANNEL_FD isoenv sh -c 'cat <&9 2>/dev/null && echo LEAK || echo closed' 2>/dev/null)
CompareArgs "$result" "closed"

Test "run: NODE_CHANNEL_FD <= 2 is not auto-kept and does not error (New-4)"
result=$(NODE_CHANNEL_FD=1 "$CRT" run --clean-env -e NODE_CHANNEL_FD isoenv sh -c 'echo ok' 2>/dev/null)
CompareArgs "$result" "ok"

Test "run: NODE_CHANNEL_FD non-numeric does not trip fd validation (New-4)"
result=$(NODE_CHANNEL_FD=notanfd "$CRT" run --clean-env -e NODE_CHANNEL_FD isoenv sh -c 'echo ok' 2>/dev/null)
CompareArgs "$result" "ok"

Test "run: keep-fd directive from config keeps the fd open"
printf 'keep-fd 3\n' > "$CRT_HOME/isoenv/config"
result=$("$CRT" run isoenv sh -c 'cat <&3' 3<<<'cfg-fd' 2>/dev/null)
CompareArgs "$result" "cfg-fd"
printf '' > "$CRT_HOME/isoenv/config"

Test "run: --keep-fd rejects a non-numeric value"
err=$("$CRT" run --keep-fd abc isoenv true 2>&1 || true)
if echo "$err" | grep -q "must be a number"; then Pass; else Fail; fi

# ── read_config: keep-fd directive ────────────────────────────────────────────
echo "# read_config keep-fd"

Test "read_config: keep-fd single"
CompareArgs "$(read_cfg_field 'keep-fd 3
' 'echo "${#config_keepfds[@]} ${config_keepfds[*]}"')" "1 3"

Test "read_config: keep-fd multiple"
CompareArgs "$(read_cfg_field 'keep-fd 3 4 5
' 'echo "${#config_keepfds[@]}"')" "3"

# ── test-mode gate (New-2) ────────────────────────────────────────────────────
echo "# test-mode gate"

Test "run: a bare CRT_TEST_MODE value does not select the mocks (New-2)"
# With CRT_TEST_MODE=1 (no marker dir) crt must NOT resolve unshare from the mocks,
# so the mock unshare never runs and logs nothing. (It then attempts a real
# namespace and, on this rootfs, fails — that is fine; we only check the mock was
# not selected, i.e. an inherited env value cannot arm test mode.)
loggate=$(mktemp)
CRT_TEST_MODE=1 CRT_MOCK_LOG="$loggate" "$CRT" run isoenv true >/dev/null 2>&1 || true
if grep -q '^unshare ' "$loggate"; then Fail; else Pass; fi
rm -f "$loggate"

Test "run: the marker-gated CRT_TEST_MODE does select the mocks"
loggate=$(mktemp)
CRT_MOCK_LOG="$loggate" "$CRT" run isoenv true >/dev/null 2>&1 || true
if grep -q '^unshare ' "$loggate"; then Pass; else Fail; fi
rm -f "$loggate"

TestDone
