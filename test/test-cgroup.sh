#!/bin/bash
# test-cgroup.sh - real cgroup v2 checks for `crt cgroup-exec` and memory limits.
# Needs root and a non-root user to delegate to:
#   sudo bash test/test-cgroup.sh [user]      (default: $SUDO_USER)
# Skips when not root, without cgroup v2, or without a non-root user.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

pass=0 fail=0
ok()  { printf 'ok     %s\n' "$1"; pass=$((pass + 1)); }
no()  { printf 'NOT OK %s\n' "$1"; fail=$((fail + 1)); }

if [ "$(id -u)" != 0 ]; then
    echo "SKIP: needs root (sudo bash test/test-cgroup.sh [user])"; exit 0
fi
if [ ! -f /sys/fs/cgroup/cgroup.controllers ]; then
    echo "SKIP: cgroup v2 is not mounted at /sys/fs/cgroup"; exit 0
fi
TUSER=${1:-${SUDO_USER:-}}
if [ -z "$TUSER" ] || ! TUID=$(id -u "$TUSER" 2>/dev/null) || [ "$TUID" = 0 ]; then
    echo "SKIP: name a non-root user to delegate to"; exit 0
fi
TGID=$(id -g "$TUSER")
THOME=$(getent passwd "$TUSER" | cut -d: -f6)
unset CRT_TEST_MODE CRT_TEST_SYSROOT CRT_TEST_EUID

UCG=/sys/fs/cgroup/user-$TUID
LEAF=cgtest$$
had_ucg=0; [ -d "$UCG" ] && had_ucg=1

# A copy of crt the target user can read, and a CRT_HOME that user owns.
WORK=$(mktemp -d -p /var/tmp crt-cg.XXXXXX)
chmod 755 "$WORK"
install -m 755 "$SCRIPT_DIR/../crt" "$WORK/crt"
CRT="$WORK/crt"
install -d -m 700 -o "$TUID" -g "$TGID" "$WORK/home"
cleanup() {
    rmdir "$UCG/$LEAF" 2>/dev/null
    [ "$had_ucg" = 1 ] || rmdir "$UCG" 2>/dev/null
    rm -rf "$WORK"
}
trap cleanup EXIT

as_user() {
    setpriv --reuid="$TUID" --regid="$TGID" --init-groups \
        env HOME="$THOME" CRT_HOME="$WORK/home" "$@"
}

echo "# crt cgroup-exec (real cgroup v2, user $TUSER uid $TUID)"

got=$("$CRT" cgroup-exec "$TUSER" --leaf "$LEAF" -- cat /proc/self/cgroup)
if [ "$got" = "0::/user-$TUID/$LEAF" ]; then ok "the command runs in user-$TUID/$LEAF"
else no "the command runs in user-$TUID/$LEAF (got [$got])"; fi

if [ "$(stat -c %u "$UCG/$LEAF")" = "$TUID" ] && [ "$(stat -c %u "$UCG")" = "$TUID" ]; then
    ok "user-$TUID and the leaf belong to $TUSER"
else no "user-$TUID and the leaf belong to $TUSER"; fi

if grep -qw memory "$UCG/cgroup.subtree_control"; then ok "memory is enabled below user-$TUID"
else no "memory is enabled below user-$TUID ($(cat "$UCG/cgroup.subtree_control"))"; fi

out=$("$CRT" cgroup-exec "$TUSER" --leaf "$LEAF" -- \
        setpriv --reuid="$TUID" --regid="$TGID" --init-groups \
        env HOME="$THOME" CRT_HOME="$WORK/home" "$CRT" doctor --limits 2>&1)
if echo "$out" | grep -q '^ok    memory limits work'; then
    ok "doctor --limits: memory limits work from inside the leaf"
else no "doctor --limits: memory limits work from inside the leaf"; printf '%s\n' "$out"; fi

# The problem cgroup-exec solves: a caller outside user-<uid> cannot join it.
case "$(cat /proc/self/cgroup)" in
    "0::/user-$TUID"|"0::/user-$TUID/"*)
        echo "# (this shell is inside user-$TUID; skipping the outside-caller check)" ;;
    *)
        out=$(as_user "$CRT" doctor --limits 2>&1)
        if echo "$out" | grep -q 'cannot move a process into'; then
            ok "doctor --limits from outside user-$TUID reports the move is refused"
        else no "doctor --limits from outside user-$TUID reports the move is refused"; printf '%s\n' "$out"; fi ;;
esac

echo
echo "passed $pass, failed $fail"
[ "$fail" = 0 ]
