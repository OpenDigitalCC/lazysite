---
id: SM1075
title: "SM1075: a rewrite into a held folder is repaired by reapply"
subtitle: "WORK-PLAN-0154 P11: files rewritten into a folder already held as a draft left the private copy in place and acl reapply refused. Reproduced on main after SM981 landed: it no longer happens. A test now holds it."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-11
raised-by: inbox 2026-10-11 (a 1,745-post local site), WORK-PLAN-0154 P11
area: security
status-note: "SHIPPED (0.15.5) as a test only: NOT REPRODUCED on main e63e1fe2. SM981 (a6106bec) made the repair merge - the private copy of a file both trees hold wins, the public one is moved to lazysite/displaced/ and named, the rest moves in. t/integration/257 passes on main and fails on a6106bec^ with the reported refusal."
---

# The report

From a local site of 1,745 posts, 2026-10-11, in the reporter's words:

> `acl set --draft` over a folder worked, with one trap: rewriting files into a
> folder that is already held leaves the private store's copy in place, and
> `acl reapply` then refuses to move the new files in ("the private store
> already holds this path"), correctly, and leaves them public in the meantime.
> Releasing the rule before replacing the files avoids it. A rewrite that names
> which of the two stores wins would help.

WORK-PLAN-0154 held it as P11, skipped while P1c ([[SM981]]) was open, to be
reproduced on main once P1c had landed, then fixed if it still failed.

# The reproduction

`t/integration/257`, in the report's shape: a folder `posts/` of three pages,
`lazysite-acl.pl set posts --draft` (which moves it into the private store),
then every page written again straight into the docroot by a tool that is not
the engine, and one new page. Then each repair the reporter could reach for:
`acl reapply --apply`, and `acl set posts --draft` issued again.

Run in throwaway worktrees, the same test on two trees:

| Tree | Result |
|---|---|
| main e63e1fe2 | passes |
| a6106bec^ (904aca3f, before SM981) | fails as reported: `reapply` exits 1, "the private store already holds this path", the folder stays in the docroot, nothing moves in |

So P11 does not reproduce on main.

# Why it no longer happens

SM981, ruled 2026-10-11 "Land where save would", changed the repair the report
hit. `Private::move_in` of a path both trees hold no longer refuses: it merges
(`_merge_in`). A file only the docroot holds moves into the store; for a file
both hold, the private store's copy wins - it is the copy the rule governs and
the engine has been serving - and the docroot's copy is moved to
`lazysite/displaced/<UTC stamp>/<path>`, outside the document root and the
store, where it can be recovered. Every displaced copy is named in the reply.
`acl reapply` and a re-issued `acl set` both go through it.

That is also the reporter's last request: the repair now names which store won
("the private store's copy is kept") and where the other copy went.

# What still holds, by design

- **The rewritten files are not the ones kept.** For a page both trees hold,
  the private copy wins and the new text is displaced. The ruling's words were
  "never expose - say which store wins and why, and keep the other as a
  recoverable backup rather than deleting it". To replace held content, write it
  through the engine (save, upload, WebDAV, MCP), which lands it in the private
  store (SM981), or release the rule first, as the reporter found.
- **Between the rewrite and the repair the bytes are in the docroot.** A file
  written past the engine is where it was written until the repair moves it.
  The engine answers 404 for it meanwhile (the folder is a draft: the test's
  first subtest, which also passed before SM981); a front end that serves the
  docroot without asking the engine would not.

# Tests

t/integration/257 - in the meantime the rewritten and the new page are 404 to
an anonymous visitor; `acl reapply --apply` and a re-issued `acl set --draft`
each succeed with no refusal, leave nothing of the folder in the docroot, move
the new page in, keep the private copy of each page both held and say so, keep
every rewritten copy under `lazysite/displaced/` and name where, and the
moved-in page is a draft to the public. Run against a6106bec^ it fails in the
two repair subtests with the reported refusal (`tmp/p11-a6106bec_.out`); that is
the sabotage - the code that fixed it, absent. No code changed.
