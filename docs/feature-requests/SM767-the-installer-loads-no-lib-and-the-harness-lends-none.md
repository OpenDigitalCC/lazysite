---
id: SM767
title: "SM767: the installer loads no lib, and the harness lends none"
subtitle: "The 0.13.5 deploy to edge died in install.pl: 'Can't locate Lazysite/Util.pm in @INC'. SM753 had pointed the installer's retention reader at the engine, the suite passed because prove -l lends every child PERL5LIB=lib, and the host had no lib to lend."
brand: plain
standard-margins: true
status: shipped
status-note: "BUILT 2026-09-07 on claude/sm767-the-installer-loads-no-lib-and-the-harness-lends-none for 0.13.6 (a deploy-blocking fix; the 0.13.5 tarball cannot be installed on a tarball host). install.pl's read_retention is self-contained again, mirroring Lazysite::Util::backup_retention (default 3, same grammar, a warning instead of a die on a bad value); t/tools/03 runs install.pl with PERL5LIB stripped, as production does, and fails on the old installer; t/lint/122 holds that install.pl neither uses nor requires a Lazysite:: module and that the two retention defaults agree."
---

# What happened

The 0.13.5 edge deploy (`update-all` → the per-site tarball deploy) ran
`install.pl` from `/tmp/lazysite-0.13.5/`, upgraded the files, invalidated
the rendered pages, and died at the retention step:

```
Can't locate Lazysite/Util.pm in @INC (...) at /tmp/lazysite-0.13.5/install.pl line 1805.
ERROR: install failed (exit 2)
```

The deploy then reported the site failed, skipped the runtime provisioning
block, and the rollout stopped. The health repair passed.

# What was true

SM753 (one reader for `backup_retention`) replaced the installer's own
parser with `require Lazysite::Util` - on the strength of a sentence in its
own filing, "the installer already loads engine modules for other reads",
which was false. install.pl's own comment says the opposite: "the installer
must not load the lib - keep the two in sync". The installer runs from an
unpacked tarball; `lib/` is in the tarball but nothing puts it in `@INC`.

The suite did not catch it because `prove -l` sets `PERL5LIB=lib` for every
child process, so `t/tools/03` ran an installer that could find the module.
That is SM473's shape - the harness supplying something production does
not - and the handoff gate, which runs that same suite, could not see it.

# What is built

- `install.pl` `read_retention` is self-contained again: default 3, the
  same grammar as `Lazysite::Util::backup_retention`, and a warning rather
  than a die on a value that is not a whole number (the installer used to
  die; the engine reads past it). The one-reader half of SM753 is therefore
  one reader **plus the installer's mirror**, held together by lint.
- `t/tools/03` runs `install.pl` with `PERL5LIB` deleted from the
  environment, as production does. Against the old installer, three of its
  subtests now fail.
- `t/lint/122`: install.pl neither `use`s nor `require`s a `Lazysite::`
  module (comments excluded), and its retention default equals
  `$Lazysite::Util::BACKUP_RETENTION_DEFAULT`.

# What the field needs

A new cut (0.13.6) and a deploy. The edge site is on 0.13.5's files with
0.13.4's runtime still running (the deploy skipped the provisioning block
after the installer failed); the retry after 0.13.6 completes both.
