---
id: SM1302
title: "SM1302: a test pipe is run through run_child"
subtitle: "SM1301 moved the 58 one-way pipe opens under t/ onto TestHelper::run_child. New t/lint/284 fails a test file that opens a pipe to or from a child itself, unless a comment says the test drives the child itself or the text is fixture text."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-23
raised-by: "SM1301, planned as n737 for 0.16.2"
area: tests
status-note: "SHIPPED (PENDING) on n737: t/lint/284 scans t/ (TestHelper.pm and t/vendor/ apart) for the '-|', '|-', forking and two-argument pipe opens and fails an undeclared one; it proves it still finds the old git helper and each shape. On the tree before SM1301 it fails on 61 sites in 56 files."
---

# What happened

SM1301 moved every one-way pipe open under t/ onto run_child. Without a check, the
next test that wants a child's output would copy the old idiom back, as the
open3 block was copied 381 times before SM1246.

# Cause

t/lint/273 holds open2 and open3 only. A one-way pipe open is a plain `open`, which
it does not read.

# Change

t/lint/284 is t/lint/273's sibling, so neither file has to change for the other.
It reads every .t, .pm and .pl file under t/ except t/lib/TestHelper.pm and
t/vendor/, and fails a line that opens a pipe to or from a child. That is an
`open` whose mode starts or ends with a bar: `'-|'` and `'|-'`, the forking
`'-|'` with no command, and the two-argument `'cmd |'` and `'| cmd'`. The handle
can be a lexical, a bareword or a glob. A pipe open inside a string, such as a
driver script a test writes, counts, as in t/lint/273.

The exemption is t/lint/273's: a comment within the six lines before saying the
test drives the child itself. A pipe open that is not a spawn at all, only text a
fixture holds, says it is fixture text. Today there are three: two fixture
strings in t/tools/100 and the users-tool stub in t/unit/manager/99, which the
manager runs.

The lint runs on the old git helper, on each shape above, on a declared pipe, on
declared fixture text, on a comment, on a file read, on a file name containing a
bar, and on a run_child call. It finds the first group and only that. On the tree
before SM1301 (946c2e952) it fails on 61 sites in 56 files: the 58 that SM1301
moved and the three that are now declared.
