#!/bin/bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CRT="$SCRIPT_DIR/../crt"
MOCKS="$SCRIPT_DIR/mocks"

export PATH="$MOCKS:$PATH"

# The mocks provide no real mount namespace, so the mock pivot_root always fails.
# Test mode lets cmd_run resolve its binaries from the mocks, fall back to chroot,
# and skip ro verification. crt enables it only when CRT_TEST_MODE names this
# repo's own test/mocks directory (with its .crt-mocks marker).
export CRT_TEST_MODE="$MOCKS"

. "$SCRIPT_DIR/Test"

# Per-test temp home; cleaned on exit. Hardened runs refuse a CRT_HOME under /tmp
# or $HOME, so use /var/tmp.
CRT_HOME=$(mktemp -d -p /var/tmp crt-test.XXXXXX)
export CRT_HOME
CRT_BIN=$(mktemp -d)
export CRT_BIN

# Hermetic xbps repo keys: _xbps_trust_keys copies *.plist from XBPS_KEYS_DIR
# into the rootfs before bootstrap. Point it at a fake dir so create tests do
# not depend on the host's /var/db/xbps/keys.
XBPS_KEYS_DIR=$(mktemp -d)
export XBPS_KEYS_DIR
printf '<plist/>\n' > "$XBPS_KEYS_DIR/fake-key.plist"

trap 'rm -rf "$CRT_HOME" "$CRT_BIN" "$XBPS_KEYS_DIR"' EXIT

# crt stores per-rootfs config outside every rootfs, at $CRT_HOME/.config/<name>.
conf() { printf '%s' "$CRT_HOME/.config/$1"; }
set_config() { mkdir -p "$CRT_HOME/.config"; cat > "$CRT_HOME/.config/$1"; }

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
    mkdir -p "$dir/bin" "$CRT_HOME/.config"
    printf '#!/bin/sh\nexec /bin/sh "$@"\n' > "$dir/bin/sh"
    chmod +x "$dir/bin/sh"
}

# Helper: write the pristine marker crt create would write for rootfs <name>
# ("dev:inode canonical-path").
mark_pristine() {
    local d
    d=$(realpath -e "$CRT_HOME/$1") || return 1
    mkdir -p "$CRT_HOME/.state"
    printf '%s %s\n' "$(stat -c '%d:%i' "$d")" "$d" > "$CRT_HOME/.state/$1.pristine"
}

# crt_run: `crt run` after re-marking every mock rootfs pristine, standing in
# for a fresh `crt create` so tests that reuse a rootfs across default and
# hardened runs keep working. Tests of the pristine rule itself call "$CRT" run.
crt_run() {
    local d
    for d in "$CRT_HOME"/*/; do
        [ -d "$d/bin" ] && mark_pristine "$(basename "$d")"
    done
    "$CRT" run "$@"
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

Test "create xbps path: config written outside the rootfs with image void"
CompareArgs "$(cat "$(conf voidenv)")" "image void"

Test "create xbps path: no config left inside the rootfs"
if [ -e "$CRT_HOME/voidenv/config" ]; then Fail; else Pass; fi

Test "create xbps path: xbps-install run with -S and keys copied"
klog=$(mktemp)
CRT_MOCK_LOG="$klog" "$CRT" create keyenv 2>/dev/null
if grep -q -- ' -S ' "$klog" && [ -f "$CRT_HOME/keyenv/var/db/xbps/keys/fake-key.plist" ]; then Pass; else Fail; fi
rm -f "$klog"

Test "create xbps path: xbps-install gets /dev/null on stdin (no key prompt)"
klog=$(mktemp)
# crt's own stdin is a pipe here; xbps-install must still see /dev/null.
printf 'y\n' | CRT_MOCK_LOG="$klog" "$CRT" create stdinenv >/dev/null 2>&1
if grep -q '^xbps-install .*stdin=/dev/null$' "$klog" \
   && ! grep '^xbps-install' "$klog" | grep -qv 'stdin=/dev/null$'; then Pass; else Fail; fi
rm -f "$klog"

Test "create xbps path: aborts clearly when no repo keys are present"
emptykeys=$(mktemp -d)
out=$(XBPS_KEYS_DIR="$emptykeys" "$CRT" create nokeyenv 2>&1 || true)
if echo "$out" | grep -q "no xbps repo keys"; then Pass; else Fail; fi
rmdir "$emptykeys"

Test "create xbps path: duplicate is rejected"
out=$("$CRT" create voidenv 2>&1 || true)
if echo "$out" | grep -q "already exists"; then Pass; else Fail; fi

Test "create OCI path: rootfs exists"
"$CRT" create ocienv alpine:3.19 2>/dev/null
if [ -d "$CRT_HOME/ocienv/bin" ]; then Pass; else Fail; fi

Test "create OCI path: config written outside with image ref"
CompareArgs "$(cat "$(conf ocienv)")" "image alpine:3.19"

Test "create config-file path: config copied verbatim (outside the rootfs)"
cat > "$CONF" << 'EOF'
image alpine:3.19
env TEST=1
EOF
"$CRT" create fileenv "$CONF" 2>/dev/null
CompareFiles "$CONF" "$(conf fileenv)"

Test "create config-file with image void: uses xbps"
cat > "$CONF" << 'EOF'
image void
env MYVAR=hello
EOF
"$CRT" create voidfromfile "$CONF" 2>/dev/null
if diff "$(conf voidfromfile)" "$CONF" >/dev/null 2>&1 && \
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
err=$(crt_run noexist echo hi 2>&1 >/dev/null || true)
if echo "$err" | grep -q "not found"; then Pass; else Fail; fi

Test "run: env var from config"
printf 'env GREETING=hello\n' > "$(conf runenv)"
result=$(crt_run runenv printenv GREETING 2>/dev/null)
CompareArgs "$result" "hello"

Test "run: -e flag sets env var"
printf '' > "$(conf runenv)"
result=$(crt_run -e COLOR=blue runenv printenv COLOR 2>/dev/null)
CompareArgs "$result" "blue"

Test "run: -e flag overrides config env"
printf 'env MODE=production\n' > "$(conf runenv)"
result=$(crt_run -e MODE=debug runenv printenv MODE 2>/dev/null)
CompareArgs "$result" "debug"

Test "run: multiple -e flags"
printf '' > "$(conf runenv)"
result=$(crt_run -e A=1 -e B=2 runenv sh -c 'echo $A-$B' 2>/dev/null)
CompareArgs "$result" "1-2"

Test "run: command exits with correct code"
crt_run runenv sh -c 'exit 0' 2>/dev/null
rc=$?
CompareArgs "$rc" "0"

Test "run: unknown flag error"
err=$(crt_run -z runenv echo hi 2>&1 || true)
if echo "$err" | grep -q "unknown option"; then Pass; else Fail; fi

Test "run: mount spec without colon is rejected"
err=$(crt_run -v /nocopath runenv echo hi 2>&1 || true)
if echo "$err" | grep -q "must be host:container"; then Pass; else Fail; fi

Test "run: memory limit warns when cgroup not available"
err=$(crt_run -m 512M runenv echo hi 2>&1 >/dev/null || true)
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

DIGEST_FILE="sha256-6a79808199d005803afc52161c0f17915bb6052587ebbdeb87a99b743f3b8e60"

Test "second create reuses cache (curl not called for blob)"
CURL_LOG=$(mktemp)
CRT_MOCK_CURL_LOG="$CURL_LOG" "$CRT" create cachetest2 alpine:3.19 2>/dev/null
blob_fetches=$(wc -l < "$CURL_LOG")
rm -f "$CURL_LOG"
CompareArgs "$blob_fetches" "0"

Test "OCI: a downloaded blob that fails its digest aborts the create"
rm -f "$CRT_HOME/.cache/layers/$DIGEST_FILE"
out=$(CRT_MOCK_BAD_BLOB=1 "$CRT" create badblob alpine:3.19 2>&1 || true)
if echo "$out" | grep -q "does not match its manifest digest" \
   && [ ! -e "$CRT_HOME/badblob" ] && [ ! -e "$CRT_HOME/.cache/layers/$DIGEST_FILE" ]; then Pass; else Fail; fi

Test "OCI: a corrupt cached blob is deleted and refetched"
printf 'corrupt\n' > "$CRT_HOME/.cache/layers/$DIGEST_FILE"
CURL_LOG=$(mktemp)
CRT_MOCK_CURL_LOG="$CURL_LOG" "$CRT" create refetch alpine:3.19 >/dev/null 2>&1
fetches=$(wc -l < "$CURL_LOG"); rm -f "$CURL_LOG"
if [ "$fetches" = 1 ] && [ -f "$CRT_HOME/refetch/bin/sh" ] \
   && sha256sum "$CRT_HOME/.cache/layers/$DIGEST_FILE" | grep -q '^6a798081'; then Pass; else Fail; fi

# ── OCI: crafted layers must not reach outside the rootfs ─────────────────────
echo "# OCI layer containment"

if command -v python3 >/dev/null 2>&1; then
    MKL="$SCRIPT_DIR/mklayer.py"
    LAY=$(mktemp -d -p /var/tmp crt-lay.XXXXXX)
    # OUT is a sibling of CRT_HOME, so from a rootfs it is ../../<OUT basename>.
    OUT=$(mktemp -d -p "$(dirname "$CRT_HOME")" crt-out.XXXXXX)
    REL="../../$(basename "$OUT")"

    # oci_escape_test NAME DESC LAYER...: create must fail, the rootfs must be
    # gone, and OUT must still hold exactly its 'victim' file.
    oci_escape_test() {
        local name="$1" desc="$2"; shift 2
        Test "OCI: $desc is refused"
        printf 'victim\n' > "$OUT/victim"
        CRT_MOCK_LAYERS="$*" "$CRT" create "$name" alpine:3.19 >/dev/null 2>&1
        local rc=$? left
        left=$(find "$OUT" -mindepth 1 | wc -l)
        if [ "$rc" -ne 0 ] && [ ! -e "$CRT_HOME/$name" ] && [ -f "$OUT/victim" ] \
           && [ "$left" = 1 ]; then Pass; else Fail; fi
    }

    python3 "$MKL" "$LAY/wh.tgz" "f:$REL/.wh.victim"
    oci_escape_test ociwh "a whiteout with '..' (would delete a host file)" "$LAY/wh.tgz"

    python3 "$MKL" "$LAY/dotdot.tgz" "f:ok" "f:$REL/dotdot"
    oci_escape_test ocidd "a '..' member" "$LAY/dotdot.tgz"

    python3 "$MKL" "$LAY/abs.tgz" "f:$OUT/abs"
    oci_escape_test ociabs "an absolute member" "$LAY/abs.tgz"

    python3 "$MKL" "$LAY/symfile.tgz" "l:lnk:$OUT" "f:lnk/pwn"
    oci_escape_test ocisf "a file through a symlink made in the same layer" "$LAY/symfile.tgz"

    python3 "$MKL" "$LAY/l1.tgz" "l:lnk:$OUT"
    python3 "$MKL" "$LAY/l2.tgz" "f:lnk/pwn"
    oci_escape_test ocixl "a file through a symlink from a lower layer" "$LAY/l1.tgz" "$LAY/l2.tgz"

    python3 "$MKL" "$LAY/h2.tgz" "h:hl:lnk/victim"
    oci_escape_test ocihl "a hardlink through a symlink from a lower layer" "$LAY/l1.tgz" "$LAY/h2.tgz"

    python3 "$MKL" "$LAY/w2.tgz" "f:lnk/.wh.victim"
    oci_escape_test ociws "a whiteout through a symlink from a lower layer" "$LAY/l1.tgz" "$LAY/w2.tgz"

    python3 "$MKL" "$LAY/hdd.tgz" "f:a" "h:hl:$REL/victim"
    oci_escape_test ocihd "a hardlink target with '..'" "$LAY/hdd.tgz"

    # The verifier's layers: names containing " -> " / " link to " used to be
    # split at the wrong place in the `tar -tv` text.
    python3 "$MKL" "$LAY/o1.tgz" "l:s2 -> q:lnk" "f:s2 -> q/pwn1"
    oci_escape_test ocio1 "a file through a symlink whose name contains ' -> '" "$LAY/l1.tgz" "$LAY/o1.tgz"

    python3 "$MKL" "$LAY/o1c.tgz" "l:s2 -> q:lnk" "d:s2 -> q/sub" "f:s2 -> q/sub/pwn1c"
    oci_escape_test ocio1c "a nested file through a ' -> '-named symlink" "$LAY/l1.tgz" "$LAY/o1c.tgz"

    python3 "$MKL" "$LAY/o2.tgz" "h:a link to b:lnk/victim"
    oci_escape_test ocio2 "a hardlink whose name contains ' link to '" "$LAY/l1.tgz" "$LAY/o2.tgz"

    Test "OCI: harmless names containing ' -> ' and ' link to ' still extract"
    python3 "$MKL" "$LAY/n1.tgz" "f:weird -> name" "f:x link to y" "f:plain"
    CRT_MOCK_LAYERS="$LAY/n1.tgz" "$CRT" create ociodd alpine:3.19 >/dev/null 2>&1
    if [ -f "$CRT_HOME/ociodd/weird -> name" ] && [ -f "$CRT_HOME/ociodd/x link to y" ]; then Pass; else Fail; fi

    Test "OCI: non-ASCII names extract, even with LC_ALL=C"
    python3 "$MKL" "$LAY/u1.tgz" "d:usr" "f:usr/café.txt"
    LC_ALL=C CRT_MOCK_LAYERS="$LAY/u1.tgz" "$CRT" create ociutf8 alpine:3.19 >/dev/null 2>&1
    if [ -f "$CRT_HOME/ociutf8/usr/café.txt" ]; then Pass; else Fail; fi

    Test "OCI: a PAX layer with sub-second mtimes extracts"
    python3 "$MKL" --pax "$LAY/p1.tgz" "d:etc" "f:etc/pax.txt"
    CRT_MOCK_LAYERS="$LAY/p1.tgz" "$CRT" create ocipax alpine:3.19 >/dev/null 2>&1
    if [ -f "$CRT_HOME/ocipax/etc/pax.txt" ]; then Pass; else Fail; fi

    python3 "$MKL" "$LAY/ctl.tgz" "$(printf 'f:bad\tname')"
    oci_escape_test ocictl "a name tar must escape (control character)" "$LAY/ctl.tgz"

    Test "OCI: a benign layered image with whiteouts and symlinks still unpacks"
    python3 "$MKL" "$LAY/b1.tgz" "d:a" "f:a/old" "d:usr" "d:usr/bin" "f:usr/bin/sh" "l:bin:usr/bin"
    python3 "$MKL" "$LAY/b2.tgz" "f:a/.wh.old" "f:usr/bin/new" "l:link2:/usr/bin/new"
    CRT_MOCK_LAYERS="$LAY/b1.tgz $LAY/b2.tgz" "$CRT" create ocibenign alpine:3.19 >/dev/null 2>&1
    R="$CRT_HOME/ocibenign"
    if [ -f "$R/usr/bin/new" ] && [ ! -e "$R/a/old" ] && [ -L "$R/bin" ] \
       && [ -L "$R/link2" ] && [ -z "$(find "$R" -name '.wh.*')" ]; then Pass; else Fail; fi

    rm -rf "$LAY" "$OUT"
else
    echo "# (python3 not found: skipping crafted OCI layer tests)"
fi

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
printf '' > "$(conf isoenv)"

# Run crt with a mock-call log and print the log to stdout.
run_logged() {
    local log
    log=$(mktemp)
    CRT_MOCK_LOG="$log" crt_run "$@" >/dev/null 2>&1
    cat "$log"
    rm -f "$log"
}

Test "run: default does not add --net to unshare"
if run_logged isoenv true | grep -q "^unshare .*--net"; then Fail; else Pass; fi

Test "run: --net none adds --net to unshare"
if run_logged --net none isoenv true | grep -q '^unshare .*--net'; then Pass; else Fail; fi

Test "run: net directive from config adds --net"
printf 'net none\n' > "$(conf isoenv)"
if run_logged isoenv true | grep -q '^unshare .*--net'; then Pass; else Fail; fi
printf '' > "$(conf isoenv)"

Test "run: --net host flag overrides config net none"
printf 'net none\n' > "$(conf isoenv)"
if run_logged --net host isoenv true | grep -q '^unshare .*--net'; then Fail; else Pass; fi
printf '' > "$(conf isoenv)"

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
err=$(crt_run --net bogus isoenv true 2>&1 || true)
if echo "$err" | grep -q "invalid net mode"; then Pass; else Fail; fi

Test "run: invalid --tmp value is rejected"
err=$(crt_run --tmp bogus isoenv true 2>&1 || true)
if echo "$err" | grep -q "invalid tmp mode"; then Pass; else Fail; fi

Test "run: long --env flag works"
result=$(crt_run --env SHADE=green isoenv printenv SHADE 2>/dev/null)
CompareArgs "$result" "green"

Test "run: long --volume flag is accepted"
tmpsrc=$(mktemp -d)
if run_logged --volume "$tmpsrc:/data" isoenv true | grep -q -- "^mount --rbind $tmpsrc "; then Pass; else Fail; fi
rmdir "$tmpsrc"

# ── cmd_run: clean environment ────────────────────────────────────────────────
echo "# cmd_run clean environment"

Test "run: default inherits caller environment"
result=$(CALLER_VAR=leaked crt_run isoenv printenv CALLER_VAR 2>/dev/null)
CompareArgs "$result" "leaked"

Test "run: --clean-env drops caller environment"
result=$(CALLER_VAR=leaked crt_run --clean-env isoenv sh -c 'echo "${CALLER_VAR:-unset}"' 2>/dev/null)
CompareArgs "$result" "unset"

Test "run: --clean-env sets a minimal HOME"
result=$(crt_run --clean-env isoenv sh -c 'echo "$HOME"' 2>/dev/null)
CompareArgs "$result" "/tmp"

Test "run: --clean-env sets a minimal PATH"
result=$(crt_run --clean-env isoenv sh -c 'echo "$PATH"' 2>/dev/null)
CompareArgs "$result" "/usr/bin:/bin:/usr/local/bin"

Test "run: -e NAME passes the caller's value through a clean env"
result=$(TOKEN=abc123 crt_run --clean-env -e TOKEN isoenv printenv TOKEN 2>/dev/null)
CompareArgs "$result" "abc123"

Test "run: -e NAME=val still works with a clean env"
result=$(crt_run --clean-env -e SHAPE=round isoenv printenv SHAPE 2>/dev/null)
CompareArgs "$result" "round"

Test "run: -e for an unset var warns and is skipped"
warn=$(crt_run --clean-env -e DEFINITELY_UNSET_VAR isoenv true 2>&1 >/dev/null || true)
if echo "$warn" | grep -q "not set in environment"; then Pass; else Fail; fi

# ── cmd_run: file descriptors ─────────────────────────────────────────────────
echo "# cmd_run file descriptors"

Test "run: --keep-fd keeps the listed fd open"
result=$(crt_run --keep-fd 3 isoenv sh -c 'cat <&3' 3<<<'fd-payload' 2>/dev/null)
CompareArgs "$result" "fd-payload"

Test "run: --keep-fd works with a clean env"
result=$(crt_run --clean-env --keep-fd 3 isoenv sh -c 'cat <&3' 3<<<'clean-fd' 2>/dev/null)
CompareArgs "$result" "clean-fd"

Test "run: an unlisted fd is closed"
result=$(crt_run isoenv sh -c 'cat <&3 2>/dev/null && echo LEAK || echo closed' 3<<<'secret' 2>/dev/null)
CompareArgs "$result" "closed"

Test "run: -e NODE_CHANNEL_FD keeps that fd open automatically"
result=$(NODE_CHANNEL_FD=3 crt_run --clean-env -e NODE_CHANNEL_FD isoenv sh -c 'cat <&3' 3<<<'ipc-msg' 2>/dev/null)
CompareArgs "$result" "ipc-msg"

Test "run: NODE_CHANNEL_FD naming an unopened fd is not kept (New-4)"
result=$(NODE_CHANNEL_FD=9 crt_run --clean-env -e NODE_CHANNEL_FD isoenv sh -c 'cat <&9 2>/dev/null && echo LEAK || echo closed' 2>/dev/null)
CompareArgs "$result" "closed"

Test "run: NODE_CHANNEL_FD <= 2 is not auto-kept and does not error (New-4)"
result=$(NODE_CHANNEL_FD=1 crt_run --clean-env -e NODE_CHANNEL_FD isoenv sh -c 'echo ok' 2>/dev/null)
CompareArgs "$result" "ok"

Test "run: NODE_CHANNEL_FD non-numeric does not trip fd validation (New-4)"
result=$(NODE_CHANNEL_FD=notanfd crt_run --clean-env -e NODE_CHANNEL_FD isoenv sh -c 'echo ok' 2>/dev/null)
CompareArgs "$result" "ok"

Test "run: keep-fd directive from config keeps the fd open"
printf 'keep-fd 3\n' > "$(conf isoenv)"
result=$(crt_run isoenv sh -c 'cat <&3' 3<<<'cfg-fd' 2>/dev/null)
CompareArgs "$result" "cfg-fd"
printf '' > "$(conf isoenv)"

Test "run: --keep-fd rejects a non-numeric value"
err=$(crt_run --keep-fd abc isoenv true 2>&1 || true)
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
CRT_TEST_MODE=1 CRT_MOCK_LOG="$loggate" crt_run isoenv true >/dev/null 2>&1 || true
if grep -q '^unshare ' "$loggate"; then Fail; else Pass; fi
rm -f "$loggate"

Test "run: the marker-gated CRT_TEST_MODE does select the mocks"
loggate=$(mktemp)
CRT_MOCK_LOG="$loggate" crt_run isoenv true >/dev/null 2>&1 || true
if grep -q '^unshare ' "$loggate"; then Pass; else Fail; fi
rm -f "$loggate"

Test "run: a relative CRT_TEST_MODE does not arm test mode (item 5)"
# A relative path (even one with a marker in cwd) must not enable test mode.
mkdir -p "$CRT_HOME/reltm"; : > "$CRT_HOME/reltm/.crt-mocks"
loggate=$(mktemp)
( cd "$CRT_HOME" && CRT_TEST_MODE=reltm CRT_MOCK_LOG="$loggate" crt_run isoenv true >/dev/null 2>&1 || true )
if grep -q '^unshare ' "$loggate"; then Fail; else Pass; fi
rm -f "$loggate"

Test "run: CRT_TEST_MODE naming another dir with a marker does not arm test mode"
foreign=$(mktemp -d -p /var/tmp crt-foreign.XXXXXX)
: > "$foreign/.crt-mocks"
printf '#!/bin/sh\necho FOREIGN >> "$CRT_MOCK_LOG"\n' > "$foreign/unshare"; chmod +x "$foreign/unshare"
loggate=$(mktemp)
CRT_TEST_MODE="$foreign" CRT_MOCK_LOG="$loggate" crt_run isoenv true >/dev/null 2>&1 || true
if grep -q -e FOREIGN -e '^unshare ' "$loggate"; then Fail; else Pass; fi
rm -rf "$foreign" "$loggate"

# ── ignore caller-exported shell functions (item 5) ───────────────────────────
echo "# exported function immunity"

Test "run: a caller-exported function named like a command is ignored"
# Export a function 'unshare'; crt must clear inherited functions and use the
# real (mock) binary, not the function.
loggate=$(mktemp)
unshare() { echo FAKE-UNSHARE-RAN; }
export -f unshare
out=$(CRT_MOCK_LOG="$loggate" crt_run isoenv true 2>&1 || true)
unset -f unshare
if ! echo "$out" | grep -q FAKE-UNSHARE-RAN && grep -q '^unshare ' "$loggate"; then Pass; else Fail; fi
rm -f "$loggate"

# ── New-6: hardened mode refuses a tainted rootfs ─────────────────────────────
echo "# New-6 pristine-rootfs requirement"

Test "create: writes a pristine marker keyed on the rootfs identity"
d=$(realpath "$CRT_HOME/voidenv")
CompareArgs "$(cat "$CRT_HOME/.state/voidenv.pristine")" "$(stat -c %d:%i "$d") $d"

Test "run: hardened run is refused without a pristine marker"
rm -f "$CRT_HOME/.state/isoenv.pristine"
err=$("$CRT" run --clean-env isoenv true 2>&1 || true)
if echo "$err" | grep -q "is not pristine"; then Pass; else Fail; fi

Test "run: hardened run is accepted with a matching marker"
mark_pristine isoenv
CompareArgs "$("$CRT" run --clean-env isoenv sh -c 'echo ok' 2>/dev/null)" "ok"

Test "run: a non-hardened run deletes the pristine marker first"
mark_pristine isoenv
"$CRT" run isoenv true >/dev/null 2>&1
if [ ! -e "$CRT_HOME/.state/isoenv.pristine" ]; then Pass; else Fail; fi

Test "run: a non-hardened run fails closed if it cannot delete the marker"
mark_pristine isoenv
chmod a-w "$CRT_HOME/.state"
out=$("$CRT" run isoenv sh -c 'echo RAN' 2>&1 || true)
chmod u+w "$CRT_HOME/.state"
if echo "$out" | grep -q "cannot remove the pristine marker" && ! echo "$out" | grep -q RAN; then Pass; else Fail; fi

Test "run: a marker for another directory (renamed/re-created) is not honoured"
mark_pristine isoenv
mv "$CRT_HOME/isoenv" "$CRT_HOME/isoenv.old"; make_rootfs isoenv
err=$("$CRT" run --clean-env isoenv true 2>&1 || true)
rm -rf "$CRT_HOME/isoenv"; mv "$CRT_HOME/isoenv.old" "$CRT_HOME/isoenv"
if echo "$err" | grep -q "is not pristine"; then Pass; else Fail; fi

Test "run: a symlinked marker file is not honoured"
d=$(realpath "$CRT_HOME/isoenv")
printf '%s %s\n' "$(stat -c %d:%i "$d")" "$d" > "$CRT_HOME/.state/elsewhere"
rm -f "$CRT_HOME/.state/isoenv.pristine"; ln -s elsewhere "$CRT_HOME/.state/isoenv.pristine"
err=$("$CRT" run --clean-env isoenv true 2>&1 || true)
rm -f "$CRT_HOME/.state/isoenv.pristine" "$CRT_HOME/.state/elsewhere"
if echo "$err" | grep -q "is not pristine"; then Pass; else Fail; fi

# ── rootfs names and aliases ──────────────────────────────────────────────────
echo "# rootfs names"

for bad in 'isoenv/' '../isoenv' '.hidden' 'a/b' '-x' ''; do
    Test "run: rejects the name '$bad'"
    err=$("$CRT" run -- "$bad" true 2>&1 || true)
    if [ -z "$bad" ]; then
        if echo "$err" | grep -q "Usage"; then Pass; else Fail; fi
    elif echo "$err" | grep -q "invalid name"; then Pass; else Fail; fi
done

Test "create: rejects an invalid name"
err=$("$CRT" create 'bad/name' 2>&1 || true)
if echo "$err" | grep -q "invalid name" && [ ! -e "$CRT_HOME/bad" ]; then Pass; else Fail; fi

Test "rm and export: reject an invalid name"
e1=$("$CRT" rm '../isoenv' 2>&1 || true); e2=$("$CRT" export 'isoenv/' sh 2>&1 || true)
if echo "$e1" | grep -q "invalid name" && echo "$e2" | grep -q "invalid name" \
   && [ -d "$CRT_HOME/isoenv" ]; then Pass; else Fail; fi

Test "run: a symlink alias inside CRT_HOME is refused"
ln -s isoenv "$CRT_HOME/aliasenv"
err=$("$CRT" run aliasenv true 2>&1 || true)
rm -f "$CRT_HOME/aliasenv"
if echo "$err" | grep -q "real directory directly under CRT_HOME"; then Pass; else Fail; fi

# ── CRT_HOME placement for hardened runs ──────────────────────────────────────
echo "# CRT_HOME placement"

Test "run: hardened run refused when CRT_HOME is under /tmp"
th=$(mktemp -d -p /tmp crt-home.XXXXXX)
CRT_HOME="$th" make_rootfs tenv; CRT_HOME="$th" mark_pristine tenv
err=$(CRT_HOME="$th" "$CRT" run --clean-env tenv true 2>&1 || true)
rm -rf "$th"
if echo "$err" | grep -q "Move CRT_HOME outside"; then Pass; else Fail; fi

Test "run: hardened run refused when a stored config mounts a path over CRT_HOME"
printf 'mount %s:/crt\n' "$(dirname "$CRT_HOME")" > "$(conf bindsenv)"
mark_pristine isoenv
err=$("$CRT" run --clean-env isoenv true 2>&1 || true)
rm -f "$(conf bindsenv)"
if echo "$err" | grep -q "the mount source"; then Pass; else Fail; fi

Test "run: a non-hardened run is not blocked by CRT_HOME placement"
th=$(mktemp -d -p /tmp crt-home.XXXXXX)
CRT_HOME="$th" make_rootfs tenv
out=$(CRT_HOME="$th" "$CRT" run tenv sh -c 'echo ok' 2>/dev/null)
rm -rf "$th"
CompareArgs "$out" "ok"

# ── hardened binds may not touch CRT_HOME, .config or .state (P9) ─────────────
echo "# hardened binds clear of CRT_HOME"

# bind_refused DESC SPEC: a hardened run with this -v must be refused.
bind_refused() {
    Test "run: hardened bind of $1 is refused"
    local err
    err=$(crt_run --clean-env -v "$2" isoenv true 2>&1 || true)
    if echo "$err" | grep -q "overlaps"; then Pass; else Fail; fi
}
bind_refused "CRT_HOME read-only" "$CRT_HOME:/crth:ro"
bind_refused "CRT_HOME read-write" "$CRT_HOME:/crth"
bind_refused "an ancestor of CRT_HOME" "$(dirname "$CRT_HOME"):/vt:ro"
bind_refused "the .state dir" "$CRT_HOME/.state:/s:ro"
bind_refused "a directory inside .config" "$CRT_HOME/.config:/c:ro"
bind_refused "its own rootfs" "$CRT_HOME/isoenv:/self"
ln -sfn "$CRT_HOME/isoenv" "$CRT_HOME.alias"
bind_refused "a symlink that resolves into CRT_HOME" "$CRT_HOME.alias:/a:ro"
rm -f "$CRT_HOME.alias"

Test "run: a hardened bind of a sibling that only shares a name prefix is allowed"
sib="$CRT_HOME-sibling"; mkdir -p "$sib"
out=$(crt_run --clean-env -v "$sib:/sib:ro" isoenv sh -c 'echo ok' 2>/dev/null)
rmdir "$sib"
CompareArgs "$out" "ok"

Test "run: a hardened run is refused when its own config binds CRT_HOME"
printf 'mount %s:/crth:ro\n' "$CRT_HOME" > "$(conf isoenv)"
err=$(crt_run --clean-env isoenv true 2>&1 || true)
printf '' > "$(conf isoenv)"
if echo "$err" | grep -q "overlaps"; then Pass; else Fail; fi

Test "run: a default (non-hardened) run may still bind CRT_HOME"
# rw bind: any :ro bind would itself make the run hardened.
out=$(crt_run -v "$CRT_HOME:/crth" isoenv sh -c 'echo ok' 2>/dev/null)
CompareArgs "$out" "ok"

# ── stored config lives outside the rootfs (New-6) ────────────────────────────
echo "# stored config location"

Test "run: config is read from outside the rootfs, not from /config in it"
# A file planted at <rootfs>/config must be ignored; the outside config wins.
printf 'env WHO=outside\n' > "$(conf isoenv)"
printf 'env WHO=inside\n' > "$CRT_HOME/isoenv/config"
result=$(crt_run isoenv printenv WHO 2>/dev/null)
CompareArgs "$result" "outside"
rm -f "$CRT_HOME/isoenv/config"; printf '' > "$(conf isoenv)"

Test "run: a legacy in-rootfs config is migrated out on first use"
make_rootfs legacyenv
rm -f "$(conf legacyenv)"
printf 'env LEG=migrated\n' > "$CRT_HOME/legacyenv/config"
result=$(crt_run legacyenv printenv LEG 2>/dev/null)
if [ "$result" = "migrated" ] && [ -f "$(conf legacyenv)" ] && [ ! -e "$CRT_HOME/legacyenv/config" ]; then Pass; else Fail; fi

Test "run: a migrated legacy rootfs is not pristine"
make_rootfs legacy2; rm -f "$(conf legacy2)"
printf 'image void\n' > "$CRT_HOME/legacy2/config"
mark_pristine legacy2
err=$("$CRT" run --clean-env legacy2 true 2>&1 || true)
if echo "$err" | grep -q "is not pristine" && [ -f "$(conf legacy2)" ]; then Pass; else Fail; fi

Test "run: a symlinked legacy /config is refused, not migrated"
make_rootfs legacy3; rm -f "$(conf legacy3)"
printf 'mount /etc:/leak\n' > "$CRT_HOME/legacy3.target"
ln -s "$CRT_HOME/legacy3.target" "$CRT_HOME/legacy3/config"
err=$("$CRT" run legacy3 true 2>&1 || true)
if echo "$err" | grep -q "not a regular file" && [ ! -e "$(conf legacy3)" ]; then Pass; else Fail; fi
rm -f "$CRT_HOME/legacy3.target"

# ── symlinked CRT_HOME works (item 4) ─────────────────────────────────────────
echo "# symlinked CRT_HOME"

Test "run: works when CRT_HOME is reached through a symlink"
real_home=$(mktemp -d -p /var/tmp); link_home=$(mktemp -u -p /var/tmp)
ln -s "$real_home" "$link_home"
CRT_HOME="$real_home" make_rootfs symenv
result=$(CRT_HOME="$link_home" crt_run symenv sh -c 'echo linked-ok' 2>/dev/null)
CompareArgs "$result" "linked-ok"
rm -rf "$real_home"; rm -f "$link_home"

TestDone
