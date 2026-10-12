---
id: SM961
title: "SM961: A submission arriving during a delete, confirm or approve could be lost"
subtitle: "The rewrite read the store, wrote a copy and renamed it over the original with no lock; an append in between went into the file thrown away."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-07
raised-by: the developer agent, found while building SM858 (approve from a submission)
area: forms
status-note: "SHIPPED (0.15.3): one sidecar lock (.<store>.lock, Lazysite::Util::store_lock) taken by the file handler around its append and by delete, confirm, bulk delete and approve across read-and-rewrite. t/unit/forms/36 forces both directions by holding the lock; each half removed fails it."
---

# What was wrong

`Lazysite::Manager::Plugins::_rewrite_store` replaces a submissions store by
writing a copy and renaming it over the original. Its callers - delete, bulk
delete, confirm, and (SM858) approve - first read the store. Nothing locked the
read-to-rename window, and the file handler's `flock` on its append was taken on
the store file itself, which the rename swaps out. A submission appended in that
window went into the file that was then discarded: the visitor was thanked and
the message was gone, with nothing logged.

# The fix

`Lazysite::Util::store_lock($path)` takes an exclusive lock on a sidecar
`.<name>.lock` beside the store - a file the rename never touches. The file
handler holds it around its append; each rewriter takes it before its read and
holds it to the rename. Approve holds it from its read through account creation
to marking the row, so two approvals cannot interleave; `_mark_approved` relies
on its caller's lock (a second flock on a new handle in one process would wait
for itself).

# Evidence

t/unit/forms/36, both directions forced by holding the lock in the test: a real
form POST in a child waits and its row survives the rewrite; a real delete in a
child does not run while the lock is held, and a row appended meanwhile is kept.
Without the appender's lock the first fails; without the delete's lock the
second. The forms, manager, plugins and integration suites pass.
