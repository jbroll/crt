# Backlog

## Memory limits for processes started outside user-<uid>

`apply_cgroup` moves the `crt` process into `/sys/fs/cgroup/user-<uid>/crt-<pid>`.
The kernel allows that only with write access to the `cgroup.procs` of the
common ancestor of the source and destination cgroups. A process started in
the root cgroup (the usual case on Void without elogind sessions) has a
root-owned common ancestor, so the move fails and the run proceeds without
limits. `crt doctor --limits` reports this; it has not yet been confirmed on a
host with `crt setup` done.

Likely fix: have the runit side place a user's service processes in a leaf
such as `user-<uid>/svc` (as root, before dropping to the user), and document
the same for interactive logins. `crt` would then move between cgroups that
share the user-owned `user-<uid>` ancestor.
