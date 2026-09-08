---
id: SM789
title: "SM789: the one-supervisor lock holds the path, not just the inode"
subtitle: "Security review, 0.13.8, VERIFIED: flock binds to the inode, and nothing re-checks that the locked descriptor still refers to supervisor.lock. Unlink and recreate the file and a second supervisor locks the new inode while the first still holds the old one - two supervisors on one docroot, which is the duplicate-scheduler condition the lock was added to prevent."
brand: plain
standard-margins: true
status: shipped
status-note: "BUILT 2026-09-08 on claude/secrev-residue-daemon-and-dav. After taking the lock, the descriptor and the path are stat-ed and their dev/ino compared; a mismatch is a failure to acquire, logged, because a lock on an unlinked inode excludes nobody."
---

# The finding

`_acquire_lock` (`Supervisor.pm:842-852`) opens `supervisor.lock`, takes a
non-blocking `LOCK_EX`, and stores the handle. `flock` binds to the open file
description, so the lock survives the file being unlinked - and a second
supervisor opening a newly created file at the same path gets a different inode
and an uncontended lock. Both then run: two schedulers, the same jobs, the same
`scheduler-runs.json`, which is the failure the lock exists to prevent and
which compounds SM787.

Same-uid boundary: the state directory belongs to the site's own unix user, so
this is a local or cleanup-tooling concern, not a remote one. The rest of the
surrounding code is careful - `_stop_children` does not unlink the lock, and
`_spawn` closes the handle in the child - so unlink-and-recreate is the only
route.

# What is asked

After taking the lock, confirm the locked descriptor still refers to the path:
`stat` the handle and `stat` the path, compare dev and inode, and treat a
mismatch or a vanished file as a failure to acquire rather than a success. A
test that unlinks and recreates the lock between two acquisitions and asserts
the second is refused pins it.

# Provenance

`inbox/2026-09-08-daemon-supervisor-lock-unlink-recreate.md`. Accepted; the
mechanism is plain in the source and the consequence is the invariant SM666
added the lock to hold.
