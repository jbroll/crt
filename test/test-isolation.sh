#!/bin/bash
# test-isolation.sh - real (unprivileged) isolation checks for `crt run`.
#
# Unlike test-crt.sh (PATH mocks, no namespaces), this exercises the actual
# unshare/pivot_root path. It builds a throwaway rootfs that reuses the host's
# binaries by bind-mounting /usr read-only, so no Void bootstrap or network is
# needed. It skips cleanly when unprivileged user namespaces are unavailable.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CRT="$SCRIPT_DIR/../crt"

pass=0 fail=0
ok()   { printf 'ok     %s\n' "$1"; pass=$((pass + 1)); }
no()   { printf 'NOT OK %s\n' "$1"; fail=$((fail + 1)); }
check() { # check "name" "expected" "actual"
    if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (want [$2] got [$3])"; fi
}

# ── skip unless unprivileged user + mount namespaces work ─────────────────────
if ! unshare --user --map-root-user --mount --pid -f true 2>/dev/null; then
    echo "SKIP: unprivileged user namespaces unavailable on this host"
    exit 0
fi
if [ ! -x /usr/bin/bash ] && [ ! -x /bin/bash ]; then
    echo "SKIP: no bash under /usr to drive the /dev/tcp network check"
fi

# ── throwaway rootfs that borrows the host /usr at run time ───────────────────
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export CRT_HOME="$WORK/home"
NAME=iso
R="$CRT_HOME/$NAME"
mkdir -p "$R"/{etc,proc,sys,dev,tmp,oldroot,usr/bin,usr/lib}
for d in bin lib lib64 sbin; do
    t="$(readlink "/$d" 2>/dev/null)" && ln -s "$t" "$R/$d"
done
printf 'image void\n' > "$R/config"          # marks it as a real env for crt

USR_RO=(-v /usr:/usr:ro)                       # every run needs the host binaries

# markers on the host that the guest must NOT see
HOST_HOME_MARKER="$HOME/.crt_iso_home_marker.$$"
echo secret > "$HOST_HOME_MARKER" 2>/dev/null || HOST_HOME_MARKER=""
HOST_TMP_MARKER="/tmp/.crt_iso_tmp_marker.$$"
echo secret > "$HOST_TMP_MARKER"
cleanup_markers() { rm -f "$HOST_HOME_MARKER" "$HOST_TMP_MARKER"; }
trap 'cleanup_markers; rm -rf "$WORK"' EXIT

# a read-only bind source with content
ROSRC="$WORK/rosrc"; mkdir -p "$ROSRC"; echo readonly > "$ROSRC/file"

# a file whose fd we hand to the child
FDFILE="$WORK/fd.txt"; echo fd-payload-42 > "$FDFILE"

echo "# crt isolation integration"

# 1. network isolation: connecting out must fail under --net none
netcheck='exec 3<>/dev/tcp/1.1.1.1/53'
bash_in_guest=/usr/bin/bash
result="$("$CRT" run --net none "${USR_RO[@]}" "$NAME" \
    "$bash_in_guest" -c "timeout 5 $bash_in_guest -c '$netcheck' 2>/dev/null && echo UP || echo DOWN" \
    2>/dev/null)"
check "network is unreachable with --net none" "DOWN" "$result"

# 2. $HOME is not visible with --no-home
if [ -n "$HOST_HOME_MARKER" ]; then
    result="$("$CRT" run --no-home "${USR_RO[@]}" "$NAME" \
        /bin/sh -c "[ -e '$HOST_HOME_MARKER' ] && echo SEEN || echo HIDDEN" 2>/dev/null)"
    check "\$HOME is not visible with --no-home" "HIDDEN" "$result"
else
    ok "\$HOME marker unwritable, skipped home visibility check"
fi

# 3. host /tmp is not visible with --tmp private
result="$("$CRT" run --tmp private "${USR_RO[@]}" "$NAME" \
    /bin/sh -c "[ -e '$HOST_TMP_MARKER' ] && echo SEEN || echo HIDDEN" 2>/dev/null)"
check "host /tmp is not visible with --tmp private" "HIDDEN" "$result"

# 4. read-only bind mount rejects writes
result="$("$CRT" run "${USR_RO[@]}" -v "$ROSRC:/ro:ro" "$NAME" \
    /bin/sh -c 'echo x > /ro/new 2>/dev/null && echo WROTE || echo RO' 2>/dev/null)"
check "read-only bind mount is not writable" "RO" "$result"

# 4b. read-only bind is still readable
result="$("$CRT" run "${USR_RO[@]}" -v "$ROSRC:/ro:ro" "$NAME" \
    /bin/sh -c 'cat /ro/file' 2>/dev/null)"
check "read-only bind mount is readable" "readonly" "$result"

# 5. clean env drops caller vars, keeps passed-through and minimal ones
result="$(CRT_LEAK=should_not_appear PASSME=kept "$CRT" run --clean-env -e PASSME "${USR_RO[@]}" "$NAME" \
    /usr/bin/env 2>/dev/null | sort | tr '\n' ' ')"
if echo "$result" | grep -q 'CRT_LEAK'; then
    no "clean env leaked CRT_LEAK: $result"
elif echo "$result" | grep -q 'PASSME=kept' && echo "$result" | grep -q 'HOME=/tmp'; then
    ok "clean env keeps only minimal + passed vars"
else
    no "clean env missing PASSME/HOME: $result"
fi

# 6. an inherited fd is readable inside the guest
result="$("$CRT" run "${USR_RO[@]}" "$NAME" /bin/sh -c 'cat <&3' 3<"$FDFILE" 2>/dev/null)"
check "inherited fd is readable inside the guest" "fd-payload-42" "$result"

# 6b. inherited fd also survives a clean environment
result="$("$CRT" run --clean-env "${USR_RO[@]}" "$NAME" /bin/sh -c 'cat <&3' 3<"$FDFILE" 2>/dev/null)"
check "inherited fd survives --clean-env" "fd-payload-42" "$result"

echo
echo "passed $pass, failed $fail"
[ "$fail" -eq 0 ]
