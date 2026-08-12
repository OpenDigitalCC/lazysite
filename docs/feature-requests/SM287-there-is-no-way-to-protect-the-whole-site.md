---
title: "SM287 - A file can be protected, a folder can be protected, the site cannot"
subtitle: "A root ACL entry is inert under every spelling. So a wholly-private site must enumerate its folders, and anything added at the top level afterwards is public by default."
brand: plain
status: candidate
status-note: "FILED 2026-08-12 from the operator's clarifying question after SM286 - 'the root / cannot be restricted as a folder, but files can, did I read that right?' They had read the design right; nothing had said so. MEASURED, not inferred: tmp probe drove the processor with a root entry under five spellings (/, empty, ., /*, *) against a top-level and a nested static, on a site declaring auth_default: required - all ten served the bytes, while a named folder and a named file gated correctly as controls. NOT STARTED."
---

# SM287 - the one scope that cannot be expressed

## The question that found it

After [[SM286]] the operator asked, to check their reading: *"the root `/`
cannot be restricted as a folder, but files can, did I read that right?"*

Yes. And it was not written down anywhere - it fell out of reading the
implementation, which is a poor way for an access-control limitation to be
discovered.

## What actually works

`_acl_entry_for` resolves in three steps: the **exact key**, then the
**section's landing page** (`foo` governs `foo.md`/`.url`/`.html`), then the
**longest matching folder prefix**. So:

- a named file - works;
- a named folder, at any depth, covering everything beneath it - works;
- **the document root - does nothing, under any spelling.**

The prefix loop skips a zero-length key outright (`next unless length $p`), and
even without that guard the match test is `index($rel, "$p/") == 0`, which an
empty prefix can never satisfy because `_acl_norm` has already stripped the
leading slash from `$rel`. So a root entry is inert **by construction**, not by
an oversight in one branch.

Measured rather than reasoned, since that is this project's rule: five spellings
(`/`, the empty string, `.`, `/*`, `*`), two statics (top-level and nested), on
a site declaring `auth_default: required`. All ten requests returned the bytes.
The two controls - a named folder and a named file - gated correctly, so the
fixture was sound.

## Why this matters more than it looks

**`auth_default: required` does not cover it.** SM223 decided deliberately that
auth_default governs pages and does not reach static files, and that decision
was right for upgrades: making it retrospective would have started refusing
assets on every live site that upgraded. But it leaves **no mechanism at all**
for "this entire site is private, including its assets". An operator who sets
`auth_default: required` on a client extranet has closed the pages and published
the PDFs.

**It fails open as content grows.** Enumerating top-level folders is a
workaround only until someone adds a new one. A file dropped at the docroot root
next month is public, and nothing in the manager, the audit trail or
`lazysite-check` will say so. The workaround decays silently, which is the same
property that made [[SM283]] survive weeks in the field.

**The UI does not offer what the engine ignores - checked.** SM267 renders a
"Protect this section" button per folder card, and a folder card is built from a
row in a directory listing. The root is never such a row, so it is never
offered. That matters: this is a **missing capability**, not an [[SM278]]-class
control that reports success and does nothing. Had the button been reachable
for the root, this filing would have been urgent rather than ordinary.

## What to build

Make a root entry mean what an operator writing it plainly intends: **everything
under this site**, as an explicit opt-in.

- Accept a canonical root key (proposed: `/`) and normalise the other spellings
  to it, or refuse them with a message naming the canonical one. Silently
  accepting `*` and doing nothing is the current behaviour and the worst option.
- It participates as the **weakest** rule: any longer prefix or exact key still
  wins, so a public carve-out inside a private site remains expressible - which
  is the common shape (a private site with a public landing page).
- `auth_default` is untouched. This is opt-in and applies only where written, so
  no upgrading site changes behaviour.
- The protected-sections panel lists it as the site-wide rule rather than as a
  folder, because reading it as one row among the folders would understate it.

## Acceptance

- A root entry gates a top-level static, a nested static and a page, for the
  anonymous public, and serves them to a permitted user.
- A more specific entry still beats it, in both directions - a public carve-out
  under a private root is served.
- The alternative spellings either normalise or are refused, and neither is
  silently accepted.
- The probe above becomes a real test - it currently fails ten of twelve.
- `lazysite-check` reports a site whose ACL store is non-empty but has no root
  rule as informational, not a warning: enumerating folders is a legitimate
  choice and this should not nag.

## Relationship to SM286

Under SM286 step 1 - gated content moves out of the document root - a wholly
private site is the clean case, not the awkward one: the docroot ends up
holding nothing but public assets, and everything else is served from the
private tree. So this filing is not superseded by SM286; it is the scope
expression that step 1 finally makes honest.

## Related

[[SM286]] (the direction), [[SM223]] (statics under access control, and the
auth_default decision this exposes the edge of), [[SM267]] (the panel), 
[[SM278]] (the class of defect this becomes if the UI offers it).
