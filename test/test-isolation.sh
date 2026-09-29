#!/bin/bash
# test-isolation.sh - real (unprivileged) isolation checks for `crt run`.
#
# Unlike test-crt.sh (PATH mocks, no namespaces), this exercises the actual
# unshare/pivot_root path. It builds a throwaway rootfs that reuses the host's
# binaries by bind-mounting /usr read-only, so no Void bootstrap or network is
# needed. It skips cleanly when unprivileged user namespaces are unavailable.
#
# The core case runs the full intended flag set together
#   --net none --no-home --tmp private --clean-env --ro-root -v ...:ro --keep-fd 3
# and asserts each hardening property from that one run, because that combination
# (ro-root with the rest) is where a bug can hide.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CRT="$SCRIPT_DIR/../crt"

pass=0 fail=0
ok()  { printf 'ok     %s\n' "$1"; pass=$((pass + 1)); }
no()  { printf 'NOT OK %s\n' "$1"; fail=$((fail + 1)); }
check() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (want [$2] got [$3])"; fi; }

# ── skip unless unprivileged user + mount namespaces work ─────────────────────
if ! unshare --user --map-root-user --mount --pid -f true 2>/dev/null; then
    echo "SKIP: unprivileged user namespaces unavailable on this host"
    exit 0
fi

# ── throwaway rootfs that borrows the host /usr at run time ───────────────────
WORK="$(mktemp -d)"
export CRT_HOME="$WORK/home"
NAME=iso
R="$CRT_HOME/$NAME"
mkdir -p "$R"/{etc,proc,dev,tmp,usr/bin,usr/lib}
for d in bin lib lib64 sbin; do
    t="$(readlink "/$d" 2>/dev/null)" && ln -s "$t" "$R/$d"
done
printf 'image void\n' > "$R/config"

HOST_HOME_CANARY="$HOME/.crt_iso_canary.$$"
echo secret > "$HOST_HOME_CANARY" 2>/dev/null || HOST_HOME_CANARY=""
TMP_MARKER=".crt_iso_tmp.$$"
echo secret > "/tmp/$TMP_MARKER"
trap 'rm -f "$HOST_HOME_CANARY" "/tmp/$TMP_MARKER"; rm -rf "$WORK"' EXIT

ROSRC="$WORK/rosrc"; mkdir -p "$ROSRC"; echo readonly > "$ROSRC/f"
FDFILE="$WORK/fd.txt"; echo fd-payload-42 > "$FDFILE"

USR_RW=(-v /usr:/usr)          # non-hardened runs: rw bind of the host binaries
USR_RO=(-v /usr:/usr:ro)       # hardened runs: read-only

echo "# crt isolation integration"

# ── combined hardened run: capture many probes from one invocation ────────────
PROBE='c=$1
echo "UID=$(id -u)"
echo "CAP=$(awk "/^CapEff/{print \$2}" /proc/self/status)"
echo "OLDROOT=$(grep -c " /oldroot " /proc/self/mountinfo)"
[ -e "$c" ] && echo "CANARY=visible" || echo "CANARY=hidden"
[ -e "/tmp/'"$TMP_MARKER"'" ] && echo "TMP=visible" || echo "TMP=hidden"
echo "DEVNULL=$(echo x >/dev/null 2>/dev/null && echo ok || echo fail)"
echo "URANDOM=$(head -c2 /dev/urandom >/dev/null 2>&1 && echo ok || echo fail)"
echo "BLOCKDEV=$(ls /dev 2>/dev/null | grep -cE "^(sd|nvme|loop[0-9]|kvm|input|video[0-9]|dri|mem)$")"
echo "ROREAD=$(cat /ro/f 2>/dev/null)"
echo "ROWRITE=$(echo x >/ro/zz 2>/dev/null && echo wrote || echo ro)"
echo "REMOUNT_ROBIND=$(mount -o remount,rw,bind /ro 2>/dev/null && echo opened || echo blocked)"
echo "REMOUNT_ROOT=$(mount -o remount,rw,bind / 2>/dev/null && echo opened || echo blocked)"
echo "NEWTMPFS=$(mount -t tmpfs x /proc 2>/dev/null && echo mounted || echo blocked)"
echo "NEWPROC=$(mount -t proc p /proc 2>/dev/null && echo mounted || echo blocked)"
echo "UMOUNT=$(umount /ro 2>/dev/null && echo unmounted || echo blocked)"
echo "FD3=$(cat <&3 2>/dev/null || echo no-fd)"
echo "ENVCOUNT=$(env | grep -c .)"'

OUT="$("$CRT" run --net none --no-home --tmp private --clean-env --ro-root \
        "${USR_RO[@]}" -v "$ROSRC:/ro:ro" --keep-fd 3 \
        "$NAME" /bin/bash -c "$PROBE" bash "$HOST_HOME_CANARY" \
        3<"$FDFILE" 2>/dev/null)"
field() { printf '%s\n' "$OUT" | sed -n "s/^$1=//p"; }

check "combined: command runs as uid 0"            "0"       "$(field UID)"
check "combined: all capabilities dropped"         "0000000000000000" "$(field CAP)"
check "combined: old root is gone"                 "0"       "$(field OLDROOT)"
if [ -n "$HOST_HOME_CANARY" ]; then
    check "combined: \$HOME canary unreachable"     "hidden"  "$(field CANARY)"
else
    ok "combined: \$HOME canary unwritable, skipped"
fi
check "combined: host /tmp not visible"            "hidden"  "$(field TMP)"
check "combined: /dev/null works"                  "ok"      "$(field DEVNULL)"
check "combined: /dev/urandom works"               "ok"      "$(field URANDOM)"
check "combined: no block/input devices in /dev"   "0"       "$(field BLOCKDEV)"
check "combined: ro bind is readable"              "readonly" "$(field ROREAD)"
check "combined: ro bind rejects writes"           "ro"      "$(field ROWRITE)"
check "combined: cannot remount ro bind rw"        "blocked" "$(field REMOUNT_ROBIND)"
check "combined: cannot remount root rw"           "blocked" "$(field REMOUNT_ROOT)"
check "combined: cannot mount a new tmpfs"         "blocked" "$(field NEWTMPFS)"
check "combined: cannot mount a new proc"          "blocked" "$(field NEWPROC)"
check "combined: cannot umount a bind"             "blocked" "$(field UMOUNT)"
check "combined: kept fd (3) is readable"          "fd-payload-42" "$(field FD3)"
envc="$(field ENVCOUNT)"
if [ -n "$envc" ] && [ "$envc" -gt 0 ] && [ "$envc" -lt 8 ]; then
    ok "combined: clean environment is minimal ($envc vars)"
else
    no "combined: clean environment not minimal ($envc vars)"
fi

# ── network isolation (separate run: the connect must fail) ───────────────────
NETCHK='exec 3<>/dev/tcp/1.1.1.1/53'
result="$("$CRT" run --net none "${USR_RO[@]}" "$NAME" \
    /usr/bin/bash -c "timeout 5 /usr/bin/bash -c '$NETCHK' 2>/dev/null && echo UP || echo DOWN" \
    2>/dev/null)"
check "network is unreachable with --net none" "DOWN" "$result"

# ── an unlisted fd is closed (no --keep-fd) ───────────────────────────────────
result="$("$CRT" run --clean-env --no-home "${USR_RO[@]}" "$NAME" \
    /bin/sh -c 'cat <&3 2>/dev/null && echo LEAK || echo closed' 3<"$FDFILE" 2>/dev/null)"
check "an unlisted fd is closed" "closed" "$result"

# ── NODE_CHANNEL_FD passed with -e is kept open automatically ─────────────────
result="$(NODE_CHANNEL_FD=3 "$CRT" run --clean-env --no-home -e NODE_CHANNEL_FD "${USR_RO[@]}" "$NAME" \
    /bin/sh -c 'cat <&3' 3<"$FDFILE" 2>/dev/null)"
check "NODE_CHANNEL_FD fd kept open automatically" "fd-payload-42" "$result"

# ── default (no isolation flags) stays unchanged: root, caps, home visible ────
DEF='echo "UID=$(id -u)"
echo "CAP0=$(awk "/^CapEff/{print \$2}" /proc/self/status | grep -q "^0*$" && echo yes || echo no)"
[ -e "$1" ] && echo "CANARY=visible" || echo "CANARY=hidden"'
OUT="$("$CRT" run "${USR_RW[@]}" "$NAME" /bin/bash -c "$DEF" bash "$HOST_HOME_CANARY" 2>/dev/null)"
check "default: command runs as uid 0"       "0"        "$(printf '%s\n' "$OUT" | sed -n 's/^UID=//p')"
check "default: capabilities retained"       "no"       "$(printf '%s\n' "$OUT" | sed -n 's/^CAP0=//p')"
if [ -n "$HOST_HOME_CANARY" ]; then
    check "default: \$HOME is visible"        "visible"  "$(printf '%s\n' "$OUT" | sed -n 's/^CANARY=//p')"
else
    ok "default: \$HOME canary unwritable, skipped"
fi

# ── New-1: an -e PATH cannot substitute crt's own unshare ─────────────────────
# A fake `unshare` earlier on PATH must never run (it would run on the host,
# unsandboxed). crt resolves unshare from a trusted path and never exports -e.
FAKE="$WORK/fakebin"; mkdir -p "$FAKE"
printf '#!/bin/sh\ntouch "%s/UNSHARE_PWNED"\n' "$WORK" > "$FAKE/unshare"; chmod +x "$FAKE/unshare"
rm -f "$WORK/UNSHARE_PWNED"
PATH="$FAKE:$PATH" "$CRT" run --no-home -e "PATH=$FAKE" "${USR_RW[@]}" "$NAME" /bin/true 2>/dev/null || true
[ -e "$WORK/UNSHARE_PWNED" ] && r=ran || r=safe
check "New-1: -e PATH cannot substitute crt's unshare" "safe" "$r"

# ── New-3: setpriv is resolved absolutely; a PATH-planted one is not used ──────
# Poison the caller PATH and -e PATH with a fake setpriv that would NOT drop caps.
# The hardened run must still be capless (real /usr/bin/setpriv), and the fake
# must not have executed.
printf '#!/bin/sh\ntouch "%s/SETPRIV_PWNED"\nexec "$@"\n' "$WORK" > "$FAKE/setpriv"; chmod +x "$FAKE/setpriv"
rm -f "$WORK/SETPRIV_PWNED"
cap="$(PATH="$FAKE:$PATH" "$CRT" run --clean-env --no-home --ro-root -e "PATH=$FAKE:/usr/bin:/bin" \
        "${USR_RO[@]}" "$NAME" /bin/sh -c 'awk "/^CapEff/{print \$2}" /proc/self/status' 2>/dev/null)"
check "New-3: caps dropped despite a PATH-planted setpriv" "0000000000000000" "$cap"
[ -e "$WORK/SETPRIV_PWNED" ] && s=ran || s=safe
check "New-3: the PATH-planted setpriv did not run" "safe" "$s"

# ── finding 7: pre-pivot setup must not follow symlinks planted in the rootfs ──
# 7a: a planted /etc/resolv.conf symlink to an outside file must not be followed
# (the outside file must keep its contents; crt removes the leaf link).
P7="$CRT_HOME/poison7a"
mkdir -p "$P7"/{etc,proc,dev,tmp,usr/bin,usr/lib}
for d in bin lib lib64 sbin; do t="$(readlink "/$d")" && ln -s "$t" "$P7/$d"; done
printf 'image void\n' > "$P7/config"
OUTSIDE="$WORK/outside_secret"; echo keep-me > "$OUTSIDE"
ln -sf "$OUTSIDE" "$P7/etc/resolv.conf"
"$CRT" run --no-home "${USR_RO[@]}" poison7a /bin/true 2>/dev/null || true
check "finding7: planted resolv.conf symlink did not truncate outside file" "keep-me" "$(cat "$OUTSIDE" 2>/dev/null)"

# 7b: a planted /dev symlink to an outside directory must be refused (abort),
# and no device placeholder may be created in that outside directory.
P7B="$CRT_HOME/poison7b"
mkdir -p "$P7B"/{etc,proc,tmp,usr/bin,usr/lib}
for d in bin lib lib64 sbin; do t="$(readlink "/$d")" && ln -s "$t" "$P7B/$d"; done
printf 'image void\n' > "$P7B/config"
OUTDEV="$WORK/outside_dev"; mkdir -p "$OUTDEV"
ln -sf "$OUTDEV" "$P7B/dev"
if "$CRT" run --no-home "${USR_RO[@]}" poison7b /bin/true 2>/dev/null; then rc7=ran; else rc7=aborted; fi
check "finding7: planted /dev symlink aborts the run" "aborted" "$rc7"
check "finding7: no device node created in the outside dir" "0" "$(find "$OUTDEV" -mindepth 1 2>/dev/null | wc -l | tr -d ' ')"

echo
echo "passed $pass, failed $fail"
[ "$fail" -eq 0 ]
