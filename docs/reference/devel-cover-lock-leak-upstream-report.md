---
title: "Devel::Cover: one `.lock` file per structure write, never removed - 4.1 million on one run"
subtitle: "A report for the Devel::Cover issue tracker, ready to paste. Written by the lazysite engine agent from the measurements in SM896; the release manager files it. Version 1.44 as packaged on Debian 13 (libdevel-cover-perl)."
brand: plain
standard-margins: true
---

# Summary

`Devel::Cover::DB::IO::Base::_lock` opens `"$file.lock"` for every read and
every write and never unlinks it. Structure files are written through a
per-process temporary name, `structure/.<digest>.<pid>`, renamed into place
- and the lock is taken on the *temporary* name, so each instrumented process
leaves one `structure/.<digest>.<pid>.lock` per structure file it writes: a
zero-byte hidden dotfile, unique by construction, removed only by
`cover -delete` (`DB::clean`), never at the end of a run and never before a
report.

On a test suite that drives real CGI subprocesses under
`PERL5OPT=-MDevel::Cover=...` (7,198 processes, ~574 instrumented files
each), one run left **4,131,376** lock files under `cover_db/structure`
beside **1,031** real structure files, on a filesystem with 4,751,360 inodes
in total. `cover -report text` then could not create its own lock and
temporary files, printed nothing, and exited 0.

# Environment

- Devel::Cover 1.44 (Debian 13, `libdevel-cover-perl`), perl 5.40
- Linux 6.12, ext4, `/srv` with 4,751,360 inodes
- Invocation: `prove -lr -j4 t/` with
  `PERL5OPT=-MDevel::Cover=-db,<db>,-silent,1,-select,...` so that forked
  and exec'd CGI processes are instrumented too

# Reproduction (small)

One test file, eight and sixteen processes, database on a scratch
filesystem, `PERL5OPT` set as above:

| Processes | Structure files | `.lock` files under `structure/` |
| --- | --- | --- |
| 8 | 9 | 69 |
| 16 | 9 | 141 |

`ls structure/` without `-a` shows only the structure files and their
`<digest>.lock` siblings - about two thousand names on the full run - which
is why the four million were not seen until `df -i` reported 0 free and
`ls -f | wc -l` was tried.

# Where it is

`Devel::Cover::DB::IO::Base`, in the distribution's `DB/IO/Base.pm`:

```perl
sub _lock {
  my ($file, $type) = @_;
  my $lock = "$file.lock";
  open my $fh, "+>>", $lock or die "Can't open $lock: $!\n";
  flock $fh, $type or die "Can't lock $lock: $!\n";
  $fh
}
```

Called from `_read` (`LOCK_SH`) and `_write` (`LOCK_EX`). Nothing unlinks
`$lock`. `Devel::Cover::DB::Structure` writes each structure file via a
per-process temp name and renames it into place, so `_write`'s `$file` - and
therefore the lock name - is the temp name, unique per (digest, pid).

# Effect

- The lock files are zero bytes, so byte-based monitoring never notices;
  the first symptom is `ENOSPC` with free space reported.
- `cover` fails silently once the filesystem is out of inodes: nothing on
  stdout, exit 0, because its own `_lock` cannot `open`... except that path
  dies - in our case the die went to a discarded stderr. Either way the
  report step produces no report.
- On a suite with many short-lived instrumented processes the lock count is
  processes x files, while the structure files deduplicate to one per source
  file.

# Suggested fix

Either of:

1. `unlink $lock` after the write completes (the temp file has been renamed
   away; nothing else can be waiting on a lock named for a pid-private
   temp), or
2. take the lock on the *final* structure path rather than the temp name,
   so at most one `.lock` exists per structure file - and remove it in
   `_write` after the rename.

And, independently, have `cover` (the report step) run the `.lock` cleanup
that `DB::clean` already knows how to do, before it reads the database.

# Workaround in use

A reaper beside the test run deleting `structure/.*.lock` older than one
minute every 30 seconds (a lock on a pid-private temp name that is a minute
old belongs to a write that has finished), plus a `find -name '*.lock'
-delete` before `cover` reads the database. Coverage figures are unaffected.
