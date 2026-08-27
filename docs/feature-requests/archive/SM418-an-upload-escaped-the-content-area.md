---
title: "SM418 (CRITICAL): a file upload escaped the content area into the auth store"
subtitle: "action_file_upload confined on the request string, not the path. The only file-write handler that never called validate_path - so `..` survived to the write, the blocklist string-matched a spelling that could not match it, and an upload overwrote the cookie-signing secret while reporting success."
brand: plain
standard-margins: true
status: shipped
status-note: "FIXED 2026-08-20, same day, ahead of everything else. Reported by the SECURITY-REVIEW agent's round-3 pass WITH A WORKING REPRODUCTION against the real handler (their tmp/repro-upload-traversal.pl - an inside-the-tree measurement the field-test account cannot make, which is how the provenance is checkable); reproduced again here against the real handler before any change (the secret really was overwritten, ok:1 really was returned) and again after (refused, secret intact). SEVERITY: an authenticated UNSCOPED manage_content editor - a content-editor grant, which is common - could write lazysite/auth/.secret and mint operator session cookies. Not reachable by token partners (file-upload is absent from the token %need map; WebDAV PUT goes through validate_path) nor by MCP upload_file (action_save_binary, guarded); a SCOPED account is stopped by _confine_scope. THREE FIXES: (1) action_file_upload routes each accepted filename through validate_path, so the blocklist sees the CANONICAL rel and symlink pivots collapse - this also closes a second exposure nobody had filed, that uploads always wrote publicly, so an upload into a gated section half-published it past SM286; (2) the %file_surface carve-out gate was keyed 'upload' while the dispatched action is 'file-upload', so it had never run for a single upload - an unscoped editor could upload onto lazysite/nav.conf without manage_nav; (3) t/lint/15, the parity lint that exists to catch exactly this, ENUMERATED five handlers in Files.pm by hand and knew nothing of Upload.pm - it now DISCOVERS every file-writing action handler and fails until each is classified guarded or exempt-with-a-reason. THAT THIRD FIX WAS THE REPORTER'S OWN SUGGESTION (their fix 3: 'a lint that lists the handlers by name proves only what someone remembered to list; one that discovers them holds when the next handler is added'), not an addition of mine. Verified: t/unit/manager/63 (five cases incl. a symlink pivot) with sabotages, and the lint proven to catch the pre-SM418 world in both its shapes."
---

# The flow, as it was

```
rel_dir = "content/../lazysite/auth"        `..` kept, only slashes stripped
-d "$DOCROOT/content/../lazysite/auth"      TRUE  - the directory really exists
realpath inside $DOCROOT?                   TRUE  - lazysite/auth really is inside
is_blocked_path("content/../lazysite/...")  MISS  - the guard is \Alazysite/
write "$DOCROOT/content/../lazysite/..."    the OS resolves `..`
```

Every check passed and every check was answering a different question from the
one that mattered. The realpath test proved the target was inside the docroot -
true, and irrelevant, because the auth store is inside the docroot.

::: widebox
A raw concatenation is not a path, it is a REQUEST - and the two differ
exactly when it matters. `validate_path` has rejected `..`, collapsed symlinks
and returned a canonical rel since SEC-2026-07 F1. This handler simply never
called it.
:::

# What made it survivable for so long

The reporter named this in the filing before any of it was built - their third
suggested fix was to make the confinement discover handlers rather than
enumerate them, on the grounds that both gaps here were one handler the
hand-maintained lists did not name. What follows is that suggestion carried
out.

`t/lint/15-write-guard-parity.t` exists to assert that every file-mutating
handler calls the guard chain. It listed five handlers in `Files.pm` by name.
`action_file_upload` is in `Upload.pm`, and was never added to the list - so
the lint passed, proving what somebody had remembered to enumerate.

It now discovers: every `action_*` in every Manager module whose **code**
(comments stripped - the first draft matched the word "rename" in a comment)
writes must be classified guarded or exempt-with-a-reason. A new handler is
unclassified and fails until somebody decides.

# Verification

`t/unit/manager/63`: the reproduced escape with the secret asserted byte-intact;
dressed-up spellings; a filename-borne traversal; a **symlink pivot**, which has
no `..` to reject and is therefore the only case that proves the per-file
validation rather than the upfront refusal; a symlink out of the docroot; and
two controls - an ordinary upload still works, a directly-named blocked target
is still refused.

One thing the sabotage matrix could **not** prove is recorded in the test
rather than papered over: deleting the `unless ($v->{ok})` guard fails nothing,
because every input reaching it is already refused upstream. It fails closed by
accident, not by decision, and the note says so.
