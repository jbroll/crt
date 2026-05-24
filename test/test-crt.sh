#!/bin/bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CRT="$SCRIPT_DIR/../crt"
MOCKS="$SCRIPT_DIR/mocks"

export PATH="$MOCKS:$PATH"

. "$SCRIPT_DIR/Test"

# Per-test temp home; cleaned on exit
CRT_HOME=$(mktemp -d)
export CRT_HOME
trap 'rm -rf "$CRT_HOME"' EXIT

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
trap 'rm -f "$CONF"; rm -rf "$CRT_HOME"' EXIT
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
bash -c "
$(awk '/^read_config\(\)/,/^\}/' "$CRT")
config_image='' config_memory='' config_cpus=''
config_mounts=() config_envs=()
read_config '$CONF' 2>/dev/null
" && Pass || Fail

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

TestDone
