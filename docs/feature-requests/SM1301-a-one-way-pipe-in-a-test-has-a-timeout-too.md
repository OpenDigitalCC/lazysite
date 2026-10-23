---
id: SM1301
title: "SM1301: a one-way pipe in a test has a timeout too"
subtitle: "SM1245 bounded every two-way open2/open3 spawn under t/ and left the one-way pipe opens - open '-|' and '|-', mostly git, find, tar and the tools under test - with no limit. All 58 of them, in 54 files, now run through TestHelper::run_child, so a child that never exits fails the test naming itself and the child."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-23
raised-by: "SM1245's own filing (\"Not changed: single-stream pipe opens\"), planned as n737 for 0.16.2"
area: tests
status-note: "SHIPPED (PENDING) on n737: every one-way pipe open under t/ (t/vendor/ apart) reads or feeds its child through run_child, the forking opens too. Two fixture strings in t/tools/100 and the manager/99 stub are declared. With LAZYSITE_TEST_CHILD_TIMEOUT=0.01 a converted test fails naming its child; before the change it passes."
---

# What happened

SM1245 moved the 381 open2/open3 blocks under t/ onto `TestHelper::run_child`,
which serves the child's pipes together and fails the test by name after
`child_timeout()`. It left the one-way pipe opens as they were, because they
cannot deadlock on a second pipe. They had no limit either. A git, find or tar
child, or the tool under test, that never exits hangs its test in the read or the
close, and nothing names it until the run's own five-hour limit.

# Cause

The one-way pipe open was the idiom for "run this and read what it prints", and
nothing offered a bounded one for it to copy, until run_child.

# Change

Every one-way pipe open under t/ except t/vendor/ runs through run_child: 58 of
them in 54 files. Each read the whole of the child's output, so none needed a
streamed read and no new TestHelper helper was added. The rewrites are mechanical:

- `open my $ph, '-|', @argv; my $o = do { local $/; <$ph> }; close $ph` becomes
  `my $o = run_child( [ @argv ], stderr => 'inherit' )->{out}`. The child's stderr
  still reaches the test's stderr, as before, and `$?` is set as close set it.
- A line-by-line read (git ls-files, find, tar tzf) splits the same output on
  newlines.
- A forking open with no command (t/tools/37, 38, 39, 40, t/integration/49, 261,
  t/unit/odoo/43) only redirected stderr and called exec. Each is now a run_child
  call, with stderr piped, merged or discarded as the old child did.
- `'|-'` to feed a child (t/tools/88, 155, t/unit/users/23, 24, 25) passes the bytes
  as `stdin =>`, and the shell string that wrote stdout to a file is gone: the
  output comes back from run_child. t/unit/forms/64's `sh -c "echo ... | perl"` is
  run_child with the JSON as stdin.

One behaviour changes: the child reads EOF on stdin, rather than the test's own
stdin.

Three sites stay, and say why in a comment within the six lines before, as
t/lint/273 has it. Two in t/tools/100 are fixture text, the source of files the
coverage digest classifies. The one in t/unit/manager/99 is inside the stub that
stands in for the users tool: the manager runs it, not the test, and TestHelper is
not loaded there.

The proof is the limit itself. With `LAZYSITE_TEST_CHILD_TIMEOUT=0.01`,
t/lint/110 fails with `child gen-doc-index.pl (pid N) was still running after 0s
and was killed`, and t/unit/tools/85 the same way for lazysite-check.pl. On the
tree before the change both pass, because nothing bounds their child. Every
changed test file passes (64 files with the OvernightRig users). The two
integration files are compile-checked only, as the integration is not run by an
agent. t/lint/284 (SM1302) holds the change.
