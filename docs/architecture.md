# Architecture

How `crt` is built and why. User-facing behavior (flags, config directives,
environment variables) is in [README.md](../README.md); this covers the
implementation.

## Single-script layout

Everything lives in one file, `crt`. Command dispatch is a `case` statement
at the bottom mapping each subcommand to a `cmd_*` function. Helpers
(`parse_image_ref`, `oci_token`, `oci_manifest`, `oci_unpack`, `parse_memory`,
`read_config`, `write_config`, `apply_cgroup`) sit above the `cmd_*`
functions they support. No build step, no other files needed at runtime;
`crt install` copies the script itself into place (see
[Install layout](#install-layout)).

`CRT_HOME` and the paths derived from it are resolved once, just before
dispatch (`resolve_crt_home`), after test mode is known, so a test sysroot can
stand in for `/data/crt`.

`read_config` populates `config_*` variables in the caller's scope via bash
dynamic scoping; callers declare the matching locals before calling it. This
avoids a struct or JSON blob for what is otherwise a dozen scalars and
arrays, at the cost of every call site having to declare the full variable
set up front.

## Create

`cmd_create` has three forms, disambiguated by the second argument: absent
(Void/xbps), an existing file (config file), otherwise an OCI image
reference. A config file's own `image` directive then picks xbps or OCI
underneath. Every path writes the stored config to `$CRT_HOME/.config/<name>`
(outside the rootfs, see [Trust model](#trust-model)), so `crt run` always
has a config to read regardless of how the environment was created. The
last step writes the pristine marker; until then an `EXIT` trap removes the
partial rootfs, config and marker (an `ERR` trap does not fire when `set -e`
aborts inside a called function). Names must match
`^[A-Za-z0-9][A-Za-z0-9._-]*$` in every command, so a name is always a single
path component with no alias forms (`x/`, `../x`, `.x`).

**xbps bootstrap** (`_create_xbps`) shells out to `xbps-install -S -r
"$rootfs"`, installing `base-minimal` from `$VOID_REPO`. No image pull, no
registry dependency — this is the default because it's fast and needs only
one tool. `-S` syncs the repository index (an empty rootfs has none). Before
installing, `_xbps_trust_keys` copies the host's repo signing keys
(`/var/db/xbps/keys/*.plist`, or `$XBPS_KEYS_DIR`) into the rootfs and fails
if there are none, and `xbps-install` gets `/dev/null` on stdin: xbps asks
before trusting a new key even with `-y`, so an unknown key fails the create
instead of prompting. Packages are signature-checked against those host keys.

**OCI pull** (`_create_oci`, `oci_token`, `oci_manifest`, `oci_unpack`) is
pure shell: `curl` for HTTP, `jq` for JSON, `tar` for layers. `parse_image_ref`
splits an image string into registry/repo/tag by inspecting the last path
segment for a tag and the first for a registry hostname (a `.` or `:` marks
it as a host rather than a Docker Hub user/org). `oci_token` and
`oci_manifest` special-case Docker Hub, ghcr.io, and quay.io auth/API
shapes and fall back to the generic OCI Distribution Spec for anything
else. `oci_manifest` resolves a multi-arch image index to the single
manifest matching `uname -m` before returning.

`oci_unpack` downloads each layer to the cache, lists its whiteout entries
with `tar -tzf` *before* extracting, applies deletions from those entries
to already-extracted lower layers, then extracts the layer and deletes the
whiteout markers it just laid down. Order matters: an opaque whiteout
(`.wh..wh..opq`) must not be able to delete files the current layer itself
just extracted, which is what a naive extract-then-sweep would do. Layer
blobs are cached at `$CRT_HOME/.cache/layers/<digest-with-colon-replaced>`,
keyed by content digest, so any environment can reuse a layer any other
environment already pulled. A blob is written to a `.tmp` path and renamed
into place on success, so a killed download can't leave a corrupt file at
the real cache path (a retry always starts clean). Each blob's sha256 is
checked against its manifest digest after download (mismatch: delete and
fail) and again before a cached copy is reused (mismatch: delete and
refetch). Only `sha256:` digests are accepted. The manifest comes from the
registry over HTTPS; its digests tie the layers to it.

A digest only proves the registry sent the layer the manifest names, not that
the layer is benign, so every layer is checked before anything is deleted or
extracted. `_oci_check_layer` refuses a layer if any member name or hardlink
target is absolute, has a `..` component, needs escaping (a backslash in the
listing), or has a parent path that runs through a symlink, whether the
symlink comes from this layer or already exists in the rootfs from a lower
layer.

Member names come from `tar -t`, one exact escaped name per line, never from
splitting `tar -tv` text: there a name containing ` -> ` or ` link to ` is
indistinguishable from the separator, which let a crafted layer write through
a symlink or hardlink a host file into the rootfs. The verbose listing, in the
same order, supplies only each entry's type, and a hardlink target is the text
after the exact name and ` link to `; any disagreement between the two
listings refuses the layer. Both listings run under `LC_ALL=C.UTF-8`, so
ordinary non-ASCII names print literally and extract; anything tar still
escapes (control characters, invalid UTF-8, a backslash, or all non-ASCII when
that locale is missing) is refused, which fails closed. The time field
accepts PAX sub-second values. That last rule is the one
tar does not enforce: GNU tar refuses `..` members, strips a leading `/`, and
defers symlinks whose targets are absolute or contain `..` to the end of the
archive, but it follows a symlink that a lower layer left behind. Image
layers record files at their real paths, so ordinary images pass. Whiteout
deletion then resolves each whiteout's parent directory with `realpath`,
requires it inside the rootfs, and removes the leaf without following it.
Extraction runs with `--no-same-owner`.

**Config files** are line-oriented, one directive per line, unknown
directives silently skipped for forward compatibility. `packages` (xbps
only) is applied after `base-minimal` via `_install_packages`, and only
when the environment was created from a config file — an inline `crt
create name image:tag` has no place to put package names.

## Run

`cmd_run` builds the isolated environment inside a single `unshare` call.
The setup script that runs inside the new namespaces is a single-quoted
`bash -c` string; every piece of data that has to cross that boundary
(rootfs path, `$HOME`, flags, mount specs, resolved env vars, the target
command) goes in as positional arguments rather than interpolated into the
string, so nothing the caller controls is ever re-parsed as shell.

### Namespaces

`unshare --user --map-root-user --mount --pid --uts --ipc [--net] -f`:
user namespace for rootless operation (caller's UID maps to root inside),
mount namespace so nothing leaks to the host, PID/UTS/IPC for process-tree,
hostname, and shared-memory isolation. `--net` is added only for `--net
none`; otherwise the container shares the host network stack.

### pivot_root and old-root detach

`crt` uses `pivot_root`, not `chroot`, and detaches the old root
unconditionally (`umount -l /oldroot`, no redirect to a path under the new
root — it may not exist or may be read-only). It then re-checks
`/proc/self/mountinfo` and aborts if the old root is still mounted. This is
the difference between `crt` and a plain chroot jail: `chroot` alone leaves
the host filesystem reachable to a process that regains root inside the
namespace (via `mkdir`/`chroot ..` games); `pivot_root` plus detach makes
the host tree actually gone from the mount table.

### Mounts

Everything mounted before `pivot_root` goes through `canon`/`safe_dir`/
`safe_file`, which resolve the target with `realpath` and refuse it if it
escapes the rootfs. This defends against a rootfs left over from an earlier
run (or crafted by whatever populated it) planting a symlink at a mount
target — e.g. `/etc/resolv.conf` — to redirect a pre-pivot `mkdir`/`mount`
onto a host path. A symlink found at a leaf is removed rather than
followed.

Order: `proc`, then `sys` (real `sysfs` bound from the host normally, a
fresh `sysfs` instance when `--net none` since the container has its own
network namespace), then a minimal `/dev` — only `null zero full random
urandom tty` bound in from the host disk device nodes (a userns-created
tmpfs forbids device writes, so `/dev` itself can't be a tmpfs), a fresh
`devpts` instance, and a private tmpfs `/dev/shm`. The host `/dev` is never
bound in whole, so block and input devices never reach the container. Then
`resolv.conf`, `/tmp` (bind or private tmpfs per `--tmp`), `$HOME` (skipped
under `--no-home`), then user `-v`/`mount` binds in the order given. A `:ro`
bind is remounted read-only (`ro=recursive` where the kernel supports it)
and then verified with `findmnt`; a still-writable submount aborts the run.
Verification is skipped only under `CRT_TEST_MODE`, where there is no real
mount namespace to check.

### Hardened mode

[Trust model](#trust-model) covers what hardened mode assumes and how `crt`
enforces it.

Requesting any isolation option (`--net none`, `--no-home`, `--tmp
private`, a `:ro` bind, `--clean-env`, `--ro-root`) turns on hardened mode.
Without one, `crt run` behaves like the original podman-based tool: root
with full capabilities, so `crt run ubuntu apt install -y perl` still
works unmodified. The logic (`hreq` vs `req` in the inner script) is: `req`
steps always abort on failure; `hreq` steps abort only when hardened. This
is the fail-closed rule — once isolation is requested, every step it
depends on must succeed or the command never runs; there's no silent
fallback to a weaker mode.

After the old root is detached, a hardened run execs the target through
`setpriv --no-new-privs --bounding-set=-all --inh-caps=-all
--ambient-caps=-all`, resolved by absolute path inside the rootfs (never a
PATH lookup, so a binary planted on PATH earlier can't run with
capabilities instead). The process keeps uid 0 (so it can still write files
the caller owns through an `rw` bind) but has no capabilities, so it can't
remount a `:ro` bind writable, remount the root, unmount a bind to expose
what's under it, or create new mounts.

Every helper `crt` runs — `unshare`, and inside the namespace `mount`,
`pivot_root`, `umount`, `findmnt`, `realpath`, `setpriv` — is resolved from
a fixed trusted `PATH` (`/usr/bin:/bin:/usr/sbin:/sbin`), never the
caller's; `unshare` itself comes from a fixed absolute list checked with
`[[ -x ]]`, so no `PATH` or function lookup is involved. Shell functions
exported by the caller are dropped at startup. `-e`/config env values are applied only to the target command
(via `env`/`env -i` in the final payload), never exported into `crt`
itself, so a caller-supplied `PATH` or `LD_PRELOAD` can't hijack `crt`'s
own execution. `--clean-env` resolves `-e` entries in the parent shell
(where the caller's environment is visible) before crossing into the
namespace, then the payload runs the command under `env -i` with a minimal
`PATH`/`HOME`.

File descriptors above stderr are closed right before the final exec,
except those named by `--keep-fd` and — if `-e NODE_CHANNEL_FD` was passed
and that fd is actually open above stderr — the fd it names. This lets a
parent hand the command an IPC channel (Node's `fork()`) without every
fd the caller happened to leak becoming reachable inside the sandbox.

### Network isolation

`--net none` adds `--net` to the `unshare` flags (a fresh, unconfigured
network namespace) and brings up loopback inside it. There's no bridge or
NAT, so the container has loopback only — outbound access requires the
default `--net host` sharing of the host stack.

## Trust model

**Hardened mode protects the host from the workload inside a hardened run.
Default mode is not a sandbox.**

A default (non-hardened) run has the invoking user's authority over the host.
It binds `$HOME` and host `/tmp` read-write, keeps full capabilities in its
user namespace, and runs the rootfs's own `umount` while the host tree is
still attached at `/oldroot`. Code in a default run can therefore change any
file that user can: any rootfs under `CRT_HOME`, any stored config, any
pristine marker. `crt` does not try to protect a hardened rootfs from default
runs, and the pristine marker cannot see such writes: it is per-rootfs, and
code in one rootfs can modify another.

The consequence: **the integrity of every hardened rootfs depends on never
running untrusted code in default mode, in any rootfs, as the same user.**
That includes `crt enter` and, for example, `crt run ubuntu apt install …`
of a package you do not trust.

Given that, a hardened run assumes:

- **The operator's environment is trusted.** Whoever invokes `crt` can run
  anything as that user anyway. `crt` drops exported functions and resolves
  its helpers from fixed paths so an accident in that environment does not
  quietly weaken a run, but it does not defend against a hostile caller.
- **The rootfs is what `crt create` wrote.** After `pivot_root` the old-root
  detach and the capability drop run the rootfs's own `umount` and `setpriv`,
  with its own loader and libc, while still privileged and while the host
  tree is attached at `/oldroot`. Exec'ing host binaries through
  `/proc/self/fd` does not help, because a dynamic binary's loader and
  libraries still resolve from the new root. A hardened run is only as safe
  as the rootfs is unmodified. `crt create` extracts image layers under the
  containment rules in [Create](#create), so a malicious image cannot write
  outside its own rootfs, but its own contents are trusted.

What a hardened run itself guarantees: it cannot reach `CRT_HOME`. The
placement check and the bind check below refuse any hardened run that would
bind `CRT_HOME`, `.config` or `.state`, whether directly, through an
ancestor, or read-only, and the pristine rule refuses a rootfs that a default
run has touched through `crt`.

### Pristine marker

`crt create` ends by writing `$CRT_HOME/.state/<name>.pristine` holding the
rootfs's identity, `dev:inode canonical-path`. A hardened run requires a
regular (non-symlink) marker whose content matches the current rootfs, and
forces the rootfs read-only. Every non-hardened run of that rootfs deletes
its marker before it starts, and does not start if it cannot.

This refuses a legacy rootfs, a migrated one, a symlink alias, a rootfs
renamed away from its name, a copy, and a different `CRT_HOME`. `cmd_run`
also requires `realpath(rootfs)` to equal `realpath(CRT_HOME)/<name>`. It
does not catch two operator actions that reproduce the same identity:

- renaming a rootfs away, running it writable under the new name (which
  removes only the new name's marker), then renaming it back;
- `rm -rf` of a rootfs followed by `mkdir` of the same name, if the
  filesystem hands out the old inode number again.

In both cases the old marker matches a tree `crt create` did not write.
Recreate a rootfs with `crt rm <name>` followed by `crt create`, which
removes the marker first, rather than by hand.

Stored config lives in `$CRT_HOME/.config/<name>`, never inside the rootfs.
A legacy `<rootfs>/config` is moved out once, only if it is a regular file (a
symlink or other type is refused), and the rootfs loses any marker, since its
history is unknown. A legacy config that is a hardlink to a file outside
`CRT_HOME` is moved as a hardlink, so the stored config keeps sharing that
inode; the rootfs is non-pristine, so this affects only default runs.

### CRT_HOME placement and hardened binds

A non-hardened run can bind `$HOME`, `/tmp` and the host side of any `mount`
line in any stored config. Before every hardened run,
`check_crt_home_placement` compares `realpath(CRT_HOME)` with each of those
paths (at or under, in either direction; `/` overlaps everything) and
refuses on any overlap, telling the operator to move `CRT_HOME` outside
`$HOME` and `/tmp`. `/data/crt/home/<user>` and `/home/crt` satisfy this.
`crt doctor` reports the same overlaps without running anything. A `CRT_HOME`
under `$HOME` or `/tmp` still works for non-hardened runs. This keeps the
common paths a default run exposes away from `CRT_HOME`; it is not a defense
against a default run, which has the user's authority regardless (above).

`check_binds_clear_of_crt` then checks the hardened run's own binds, from
flags and from its stored config. Any bind whose host side is, contains, or
sits inside `CRT_HOME`, `.config` or `.state` is refused, `:ro` included,
since a read-only bind still exposes other rootfs configs. Paths are
compared after `realpath`, and `.config` and `.state` are resolved on their
own in case either is a symlink out of `CRT_HOME`.

### Residuals

- Rename-and-back and inode reuse after a manual `rm`/`mkdir` give a stale
  pristine marker (above). Recreate with `crt rm` then `crt create`.
- A hardlinked legacy config keeps sharing its inode after migration (above).
- `--keep-fd N` passes an open descriptor through unchanged. A directory fd the
  operator opened on `CRT_HOME` would reach it from a hardened run; that is an
  operator action.
- Exported functions named like the bash builtins `crt` uses to drop
  inherited functions (`compgen`, `unset`, `builtin`, `command`, `declare`)
  can still shadow them. Only the environment that invokes `crt` can set
  them. Running under bash's POSIX mode, where special builtins such as
  `unset` take precedence over functions, or re-executing under `env -i`
  with an allow-list, would close it; `crt` does neither, because the
  invoking environment is trusted.

## Install layout

On a shared host each user gets their own `CRT_HOME` under a root-owned
prefix, default `/data/crt`:

```
/data/crt/              root, 755
  bin/crt               root, 755; /usr/local/bin/crt links here
  home/                 root, 755
    <user>/             owned by <user>, 700: that user's CRT_HOME
```

The pieces follow from the trust model:

- **Per-user, 700 `CRT_HOME`.** A default run has its user's authority, so
  it can change any rootfs that user owns. Separate owners mean a default run
  as `john` cannot touch the hardened rootfs of `s-ci`. The trust rule
  ("never run untrusted code in default mode as the same user") then applies
  per user rather than to the whole host.
- **Outside every `$HOME`.** Service accounts often have homes on the same
  disk (`s-ci` has `/data/ci`), so the layout keeps `CRT_HOME` in its own
  subtree rather than under the home directory, which a default run binds.
  `crt setup` warns when a user's home would contain their `CRT_HOME`.
- **Root-owned `home/`.** Users cannot create, rename or replace entries in
  it, so no one can plant a directory or symlink under another user's name.
  `setup` refuses an existing `home/<user>` that is a symlink or not a
  directory.
- **Root-owned `bin/crt`.** The script is what enforces hardened mode. A copy
  a user owns could be edited by any default run as that user, and a later
  hardened run would execute the edited copy.

`crt install` copies the running script (resolved with `realpath`) to a
temporary file in `bin/`, sets root ownership and 755, and renames it over
`bin/crt` with `mv -T`, so there is never a moment where `bin/crt` is
user-owned or partially written. It skips the copy when the content is the
same (sha256), which makes it idempotent. `/usr/local/bin/crt` becomes a
symlink to it, replacing a regular file left by an older `cp` install.
Before creating anything, `check_root_only_path` walks from the prefix's
parent up to `/` (after `realpath`) and refuses if any directory is not owned
by root or is group- or other-writable without the sticky bit: a user who
could rename a parent could swap the installed tree.

`crt setup` looks every named user up with `getent passwd` before changing
anything, so one unknown name aborts the whole run with no side effects. It
takes users from its arguments, falling back to `SUDO_USER`. The home
directory it compares against comes from the passwd entry, not from the
environment, since under `sudo` `$HOME` may be root's. When the prefix does
not exist, setup only delegates cgroups, and the user keeps `/home/crt`.

`CRT_HOME` resolution is `$CRT_HOME`, then `/data/crt/home/$(id -un)` if it
exists, then `/home/crt`. The layout directory has to exist before it is
used, so hosts without `/data/crt` are unaffected. `id -un` is used instead of
`$USER`, which runit and `su` may leave unset or stale. A non-default
`--prefix` is not searched; those users set `CRT_HOME`. `CRT_BIN` defaults to
`$CRT_HOME/bin` only when the layout was picked, so an existing
`CRT_HOME=/x` setup keeps its wrappers in `/home/crt/bin`.

Root-only commands (`install`, `setup`) reset `PATH` to the trusted
`/usr/bin:/bin:/usr/sbin:/sbin`, like `cmd_run`.

### crt doctor

`crt doctor` runs the checks a hardened run would make, without running
anything in a rootfs, and exits 1 on a failure. A harness calls it before
creating a rootfs:

- `CRT_HOME` owned by the caller and not group- or other-writable (another
  user who can write it can change a rootfs), or, if missing, a writable
  parent;
- the `check_crt_home_placement` overlaps, from the same
  `crt_home_exposures` list;
- `unshare --user --map-root-user --mount --pid -f true` succeeds, using the
  same fixed-path `unshare` as `cmd_run` (`find_unshare`).

The cgroup probe mirrors `apply_cgroup`: cgroup v2, a writable
`user-<uid>`, `memory` in its `cgroup.controllers`, then a child cgroup
where it writes `memory.max` and moves a subshell in. The last step catches
the kernel's delegation rule: moving a process needs write access to the
`cgroup.procs` of the common ancestor of the source and destination cgroups.
A process started outside `user-<uid>` (for example in the root cgroup) has
that ancestor owned by root, so it cannot join its own delegated cgroup, and
`apply_cgroup` warns and runs without limits. Limits are not needed for
hardened isolation, so the probe only warns unless `--limits` is given.

## Resource limits (cgroups)

`apply_cgroup` runs in the parent, before `exec unshare`, so the cgroup
membership applies to the whole namespace tree. It targets
`/sys/fs/cgroup/user-$UID/crt-$$`, not the cgroup root — cgroup v2 forbids
putting processes in a cgroup that has controllers enabled in its own
`subtree_control`, so limits are only assignable in a delegated leaf.
`crt setup` (root-only) is what creates `/sys/fs/cgroup/user-$UID/` and
enables `+memory +cpu` in the parent's `subtree_control`; without that
step `apply_cgroup` finds no delegated directory and warns rather than
failing the run. `crt setup` takes any number of users and does this for
each. On runit (Void) `crt setup` also installs
`/etc/sv/crt-cgroup/`, a service that redoes the delegation for every
username listed in `/etc/crt-users` on boot, since the cgroup tree doesn't
survive a reboot. Other init systems get printed manual steps instead of
an installed service.

## Testing

Two independent suites, at different levels — see
[README.md § Testing](../README.md#testing) for how to run them.

`test/test-crt.sh` runs the real `cmd_create`/`cmd_run` code paths with no
root, namespaces, network, or xbps, by shadowing `unshare`, `pivot_root`,
`chroot`, `mount`, `curl`, and `xbps-install` with scripts on `PATH`
(`test/mocks/`). Test mode is enabled only when `CRT_TEST_MODE` resolves to
this repository's own `test/mocks` directory (found from the script's real
path, carrying `.crt-mocks`). Any other value, including another directory
with a marker, does nothing, and an installed `crt` has no such directory.
When active, it takes `unshare` from the mocks, prepends the mocks
directory to the in-namespace `PATH`, lets `cmd_run` fall
back to `chroot` when the mock `pivot_root` (which always fails) is
invoked, and skips read-only bind verification, since there's no real
mount namespace for `findmnt` to inspect. The pristine rule stays in force
under test mode; a `crt_run` helper re-marks the mock rootfs before each
run, standing in for `crt create`. `CRT_HOME` is created under `/var/tmp`
because hardened runs refuse one under `/tmp`.

Test mode also enables two variables for the root-only commands.
`CRT_TEST_SYSROOT` is prefixed to `/data/crt`, `/usr/local/bin`,
`/sys/fs/cgroup`, `/etc/sv`, `/etc/crt-users`, `/etc/runit`, `/run/runit` and
`/var/service`, and `CRT_TEST_EUID` replaces `id -u` in the root check. The
invoking user then counts as root for `check_root_only_path`, and mock
`chown`, `getent` (reading `CRT_MOCK_PASSWD`) and `sv` stand in for the
calls a non-root test cannot make. The doctor tests build a fake cgroup tree
in the sysroot; ordinary files accept the `memory.max` and `cgroup.procs`
writes, so the pass path is exercised too.

`test/test-isolation.sh` is the real thing: it builds a throwaway rootfs
that reuses the host `/usr` (bind-mounted read-only) and runs actual
`unshare`/`pivot_root` namespaces, mostly from one invocation with the full
isolation flag set. It proves the properties the mock suite can't: the old
root is actually gone, the capability drop actually blocks remount/
unmount/new-mount, the minimal `/dev` has no block or input devices, a
`:ro` bind actually rejects writes, a planted `resolv.conf`/`/dev` symlink
is not followed, a rootfs that was run writable or has legacy config is
refused for hardened use, a hardened run cannot bind `CRT_HOME` (rw, ro, or
through an ancestor), and a default (non-hardened) run is unchanged.

The OCI containment rules are tested in the mock suite with crafted layers
(`test/mklayer.py`, needs python3): `..` and absolute members, whiteouts and
hardlinks with `..`, files, hardlinks and whiteouts through a symlink
created in the same layer or a lower one, the same through members whose
names contain ` -> ` or ` link to `, and names tar must escape. Harmless
names containing those phrases, non-ASCII names (under `LC_ALL=C`) and PAX
sub-second mtimes must still extract. Each must fail the create and
leave a file outside the rootfs untouched; a benign layered image with
whiteouts and symlinks must still unpack. It
self-skips when unprivileged user namespaces aren't available on the host.
