---
id: SM1245
title: "SM1245: a test child never deadlocks on its pipes"
subtitle: "t/unit/dav/33 sat 95 minutes in the 2026-10-20 14:30 suite run on a lazysite-dav.pl child. TestHelper::run_dav, and 381 copies of the same open3/open2 block in 232 files under t/, read one pipe to EOF before the other with no limit. TestHelper::run_child now serves stdin, stdout and stderr together and fails the test by name after a timeout; every one of those blocks runs through it."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-22
raised-by: "task #370: t/unit/dav/33 hung 95 minutes in the 2026-10-20 14:30 suite run (tmp/nightly/2026-10-20.log: 6659 s wall, against about 600 for the runs either side)"
area: tests
status-note: "SHIPPED (0.16.1) on n726: TestHelper::run_child (with feed_child, reap_child, child_timeout); the TestHelper helpers, ManagerSession, MaintenanceRig and every test's own open2/open3 block run through it; t/unit/dav/33 and t/tools/200, which signal their child, use feed_child and reap_child. New t/unit/lib/207 hangs on the old run_dav."
---

# What happened

The 2026-10-20 14:30 suite run took 6659 seconds against about 600 for the runs
either side, and t/unit/dav/33 was the last file to finish. Task #370 records 95
minutes on a lazysite-dav.pl child. The file passed in the end; the log does not
show which of its children waited or what released it. Nothing bounded the wait
but the run's own five-hour limit, and every child the file ran could wait that
way: see Cause.

# Cause

TestHelper::run_dav wrote the body to the child, read its stdout to EOF, then read
its stderr, then called waitpid, all with no timeout. A child that writes more than
a pipe holds (64 KiB) to stderr blocks on that write. The test blocks reading
stdout, and neither ever moves again. A child that does not exit hangs the test
with nothing to name it.

The same block was copied into the suite 381 times, in 232 files: open3 with a
stderr pipe read after stdout, or never read at all; open2 writing the whole of
stdin before reading anything; `qx` and a forked pipe in TestHelper itself. None
had a limit. t/unit/dav/33 also wrote 200 KB to a child with a blocking syswrite
while nobody read the child's stdout or stderr, then waited for it after SIGTERM
with no limit.

# Change

`TestHelper::run_child( [ @argv ], %opt )` runs a child without a shell. It writes
stdin while it reads stdout and stderr through IO::Select, so no pipe fills while
the other end waits. It returns `{ out, err, status, written, stdin_error }` and
sets `$?`. stderr can be piped (the default), merged into stdout, inherited,
discarded or sent to a handle. A child still running at the timeout gets TERM and
then KILL, and the test dies with its own name, the child's name and how long it
waited: `t/unit/dav/33-...t: child lazysite-dav.pl (pid N) was still running after
300s and was killed`.

The timeout is `child_timeout()`: 300 seconds, or 1200 under Devel::Cover, which
makes every Perl child several times slower. `LAZYSITE_TEST_CHILD_TIMEOUT`
overrides both. A test's child is one CGI request or one tool run; five minutes
leaves room for a loaded host at `prove -j4` and still ends a hang.

run_cmd, run_script, run_processor, run_dav and dav_users_tool now run through it,
as do ManagerSession and MaintenanceRig. Every test's own open2/open3 block was
moved onto it. A test that signals its child, or reads it while it runs, still
holds the pid: t/unit/dav/33's SIGTERM case and t/tools/200's dev server. dav/33
now sends its child's output to files and writes its input with `feed_child`;
both wait with `reap_child`. Each is bounded by the same limit and fails the same
way.

t/unit/lib/207 proves it. Its child writes 200 KB to stderr before any stdout,
through run_child and through run_dav itself (a module loaded into the real
lazysite-dav.pl). A 1 MB body is echoed back. A child that never exits fails in
bounded time and names itself, through run_child, through run_dav and as a whole
test file. With the old run_dav restored, the test stops after its fourth
assertion, and an external `timeout 90` kills it.

Not changed: single-stream pipe opens (`open my $ph, '-|', ...`), mostly git and
find in the lint and tools tests, cannot deadlock on a second pipe and are left
as they are, and so are the children tests fork themselves.
