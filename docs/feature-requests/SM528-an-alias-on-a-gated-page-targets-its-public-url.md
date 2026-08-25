---
title: "SM528: an alias on a gated page targets its public URL"
subtitle: "An alias declared on a page that lives in the private store is indexed against the store path, so the alias points nowhere and can never be removed."
brand: plain
standard-margins: true
status: candidate
status-note: "FOUND 2026-08-25 by the path-core structural review, PROVEN by probe tmp/pathcore-probe.t (P2, evidence in tmp/pathcore-probe.out); class: correctness; recommended timing: 0.10.33. PLANNED under SM516 for 0.10.33 unless the operator pulls it forward. Saving members/x.md with aliases: [/old-x] into a gated section writes the alias map row /old-x -> /-lazysite-private/members/x. Manager/Files.pm 536 derives the alias rel by stripping the docroot from the full path, and for a gated page the full path is the private store path; action_delete at 811 does the same, so the bogus row can never be de-indexed either. Fix: pass the validated rel, which is already in hand."
---

# The finding

Saving `members/x.md` with `aliases: [/old-x]`
into a gated section writes the alias map row `/old-x ->
/-lazysite-private/members/x`. `Manager/Files.pm 536` derives `$arel` by
stripping `$DOCROOT/?` from `$full`, and for a page in the private store
`$full` is the store path rather than the public path. `action_delete`
(`Manager/Files.pm 811`) makes the same derivation, so the row can never
be de-indexed either.

# Why it matters

Correctness: an alias is a promise that an old URL still leads
somewhere. Indexed against the store path, the promise leads to a path
that is never served, and because delete makes the same mistake the stale
row survives every later edit.

# The proving test

A new assertion in `t/unit/manager/71-acl-moves-content.t`: "an alias on
a gated page targets its public URL".

# Fix shape

Pass `$result->{rel}` from `validate_path` to the alias indexer and
de-indexer instead of re-deriving the rel from the full path.
