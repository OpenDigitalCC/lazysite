---
title: "SM527: a lock is keyed by the canonical path"
subtitle: "A lock taken under one spelling of a path is invisible to a save under another spelling, so two editors can write the same page at once."
brand: plain
standard-margins: true
status: candidate
status-note: "FOUND 2026-08-25 by the path-core structural review, PROVEN by probe tmp/pathcore-probe.t (P1, evidence in tmp/pathcore-probe.out); class: correctness; recommended timing: 0.10.33. PLANNED under SM516 for 0.10.33 unless the operator pulls it forward. The lock key in Manager/Files.pm is derived from the request spelling at seven sites rather than from the canonical rel that validate_path already computes, so content/p.md, ./content/p.md, content//p.md and /content/p.md mint four different keys for one file. MCP passes /slug.md and the API passes the path as typed, so the two channels already differ by a leading colon and never see each other's locks. Fix: derive the key from validate_path's rel at every site; the PC-1 helper makes that one line."
---

# The finding

The lock key in `Manager/Files.pm` is the request spelling:
`acquire_lock('content/p.md', 'alice')` followed by an `action_save` of
`./content/p.md`, `content//p.md` or `/content/p.md` by bob all return
`ok:1` - the lock is never seen. The listing's lock glyph builds
its key from `/content/p.md` (`Manager/Files.pm 300`), so it never
shows a lock taken as `content/p.md` either. MCP passes `"/$slug.md"`
(`lazysite-mcp.pl 2889, 2944`) and the API passes `$params{path}` as
typed (`lazysite-manager-api.pl 355`), so the two channels already mint
keys that differ by a leading colon. The key derivation is written seven
times (`Manager/Files.pm 300-301, 398-400, 503-505, 882-884, 1202-1204,
1231-1233, 1251-1253`).

# Why it matters

Correctness: the lock exists so that one editor's work is protected from
another's save. When the key depends on how the path was spelled, that
protection holds only between callers who happen to spell the path the
same way, and the two main write channels spell it differently by design.

# The proving test

Add to `t/unit/manager/08-lock-interop.t` the assertion "a lock taken as
content/p.md refuses a save spelled /content/p.md".

# Fix shape

Derive the lock key from `validate_path`'s `rel` at every site. The
review's PC-1 extraction (`_lock_file($rel)`) reduces this to a one-line
change once the helper exists; PC-1 itself must keep taking the raw
request path until this filing lands.
