---
title: "SM310 - acl-get cannot see the site-wide rule"
subtitle: "SM287 taught both writers and the sections panel that '/' means the whole site, and left the one per-path reader behind. A rule in force on every request reads back as absent."
brand: plain
status: shipped
status-note: "SHIPPED alongside SM306 on claude/sm305-principal-picker-and-polish. FOUND 2026-08-15 by a control subtest, not by review: an assertion written to prove the SM306 fix had NOT broken site-wide rules wrote one and could not read it back. The defect shipped in 0.10.8 with SM287 and survived 0.10.9. Second time this store's root handling was fixed on one side and left on the other - SM287's own note records the first as 'found by the writer test, not by review'. Both times the remedy was a test that made a ROUND TRIP rather than checking one direction, which is the transferable lesson."
---

# SM310 - enforced, listed, and unreadable

## What was found

`action_acl_set` stores a site-wide rule under the canonical key `/`.
`action_acl_get` looked it up through `validate_path` and then `_acl_norm`,
which strips leading slashes - so the key `/` became the lookup key `''` and
missed. The reply was:

```json
{"ok":1,"path":"","acl":null}
```

while the rule was present in the store and being enforced on every request.

## What SM287 did and did not reach

```datatable
columns: Reader or writer | Understands '/' as the whole site
widths: 7.6cm | X
bold: 1
tone: medium
---
`action_acl_set` (writer) | yes, since SM287
`action_acl_remove` (writer) | yes, since SM287
`action_protected_sections` (reader) | yes - lists it with `site_wide: 1`
`action_acl_get` (reader) | **no**
---
```

SM287 was thorough about the writers, and deliberately so: its own note records
that remove had to understand the same spellings as set, "or a site-wide rule
can be created and not taken off - which is a worse trap than not being able to
create one," and that this was found by the writer test rather than by review.
The same care did not extend to the per-path reader.

## Why it went unnoticed

**The sections panel was right throughout.** An operator looking at the screen
built to answer "what is held back?" saw the rule listed and flagged
`site_wide`. Nothing looked wrong from the outside, so the disagreement between
the two readers of one store had nothing to draw attention to it.

The reader that was wrong is the one a caller checking a *specific* path uses -
including anything reconciling a path against the rule that governs it. That is
the quieter and more consequential of the two.

## Severity

Bounded, and worth stating plainly rather than overstating:

- The rule is **enforced** correctly - this is a reporting defect, not a gap in
  access control.
- The rule is **removable** - `acl-remove` understands the root, so a site taken
  private by accident (SM306) can still be recovered.
- The rule is **listed** by the sections panel, so the primary operator surface
  was accurate.

What was broken is the per-path question, and any caller that trusted it would
conclude the site root carried no rule when it did.

## The fix

`action_acl_get` now uses `_acl_root_key` exactly as `action_acl_remove` does:
the four root spellings resolve to the canonical `/`, the store is searched for
whichever spelling is actually present (a hand-edited store may hold any of
them), and glob spellings are refused with a message naming `/` rather than
quietly returning null - because a reader answering "nothing" for `*` would
imply the pattern was understood and matched nothing.

## Verification

`t/unit/manager/74-acl-get-reads-the-root.t`, shown to fail before the fix:

- a rule written by the real writer reads back through all four root spellings,
  each reporting the canonical path;
- `acl-get` agrees with `protected-sections` about who may read;
- a glob spelling is refused, naming `/`;
- an ordinary folder path is unaffected, so the root branch captures nothing it
  should not.

The fixture is written by `action_acl_set` rather than by hand. SM292 is why:
the protected-sections tests built `acls.json` themselves with trailing slashes,
so they agreed with each other and never with the writer, and the panel was
empty for every operator using the supported route while its tests passed.

## Related

SM287 (which made a root rule effective and taught both writers), SM306 (which
makes such a rule harder to create by accident), SM292 (the hand-built fixture
that hid a defect of exactly this shape), and
`inbox/archive/2026-08-15-0.10.9-validation.md`, the field test whose section 8
started this thread.
