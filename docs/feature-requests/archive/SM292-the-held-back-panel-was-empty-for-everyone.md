---
title: "SM292 - The 'held back' panel was empty for everyone who used the supported route"
subtitle: "SM267 built a screen to say which sections are held back. It filtered on a trailing slash; the writer stores keys without one. It listed hand-edited entries and nothing else."
brand: plain
status: shipped
status-note: "FILED AND SHIPPED 2026-08-13 on main (unreleased). Found while flipping the SM286 move, by a test that drove the panel from action_acl_set instead of from a hand-written acls.json. Fixed by treating a key that names a FOLDER as a section, whichever way it is spelled; per-file rules stay excluded. The counts now follow content into the private store as well, or every gated section reads as 0 pages the moment protecting it succeeds. t/unit/manager/72 verified failing on the stashed tree."
---

# SM292 - the screen that was built to prevent exactly this

## What was wrong

`action_protected_sections` selected the entries to show with:

```perl
next unless $key =~ m{/\z};    # sections, not files
```

`validate_path` derives the stored ACL key from `realpath`, which never has a
trailing slash. So a rule an operator created by typing `members/` into the
manager - or over MCP, or over the control API - is stored under the key
`members`, and the panel skipped it.

The panel listed only entries that had been written into `acls.json` by hand.
For everyone using a supported surface, it was empty.

## Why this one is worth reading twice

SM267 built this screen for a stated reason:

> the product could hold a section back and had no screen that said which
> sections were held back, which is the failure mode of a good hiding
> mechanism: a section left in draft after launch stays invisible and nothing
> says so.

The screen existed. It was empty. The failure mode it was built to prevent was
the failure mode it had.

## Why the tests agreed with it

`t/unit/manager/66-protected-sections-and-holders.t` writes `acls.json` directly,
with trailing-slash keys. The fixture agreed with the reader, and neither of them
ever met the writer.

That is the general shape, and it is worth naming because it is not specific to
this panel: **a reader tested only against a fixture is tested against an
assumption, not against the product.** The same two components, driven from the
writer, disagree immediately.

`t/unit/manager/72-protected-sections-sees-real-keys.t` authors no ACL store at
all. Every entry it tests comes from `action_acl_set`. That property, rather than
any individual assertion in it, is what would have caught this.

## The fix

A section is a key that names a **folder**, which is not the same thing as a key
ending in a slash. The check resolves the key and asks whether it is a directory,
in either tree.

Per-file rules are still excluded, deliberately - the panel is sections-only
because mixing in hundreds of per-file ACLs would bury the few entries that
matter. The fix must not turn every protected file into a row, and a control in
the new test pins that.

## The second half (SM286)

Protected content now lives outside the document root. The panel counted pages
and assets with:

```perl
my $dir = "$DOCROOT/$key";
```

which reports every gated section as **0 pages, 0 assets, exists: false** - "held
back and empty" - at the exact moment protecting it succeeded. An operator would
reasonably read that as their content having been destroyed by the act of
protecting it.

The count now resolves through `Lazysite::Private`, so it follows the content.

## Related

- SM267 - the panel this is about
- SM286 - the private content store, whose flip surfaced it
- SM261 - the same class on the history response: a wrong key and an empty
  result are indistinguishable to a caller, so the failure is a confident wrong
  conclusion rather than an error
