---
title: "Lazysite manager - the walkthrough guide"
subtitle: "Every menu item, what to do with it, what to expect, and what a user without the capability should see."
brand: plain
standard-margins: true
---

# What this is

A **menu-complete** walkthrough of the lazysite manager. Every item in the
manager navigation has an entry here, or an explicit note saying why it does not.
So does every way an agent connects.

It exists for three readers, and the same longlist serves all three:

a person reviewing the product
: the automated suite proves behaviour; it cannot tell you a button works, that a
  page reads well, or that a refusal explains itself. This walks the whole
  surface rather than the paths that happen to have a test.

an agent being onboarded
: the connector, token and WebDAV flows are here alongside the browser UI,
  because a partner's first hour is spent on those and nowhere else.

whoever writes the tutorials
: if an item is in this guide, a tutorial is owed for it. That is the rule, and
  this is the checklist.

# The per-item template

Every entry has the same four parts, in the same order:

Where
: the menu path, exactly as it appears.

Do
: the action to take.

Expect
: the observable result - what changes on screen, what is written, and what
  lands in the audit trail.

Negative
: what a user WITHOUT the governing capability should see. This is the part
  reviewers skip and the part that matters: a capability that is not enforced
  looks identical to one that is, until someone checks.

# How to run a pass

Sign in as an operator (a member of a group holding the capability under test),
and keep a second browser signed in as a **deliberately under-privileged** user -
an account in a group with, say, `manage_content` and nothing else. Most Negative
rows need it, and making one per section is how a pass turns into an afternoon.

Work a chunk at a time. Each is self-contained, so a reviewer can take one
section without holding the whole guide in their head.

## What this guide does NOT cover

`docs/MANUAL-CHECKS.md` is the companion, and the split is deliberate: this guide
is **menu-complete coverage**, that document is **the things the suite
structurally cannot reach and why**. When a manager panel ships with no automated
coverage, its verification steps go there and its menu entry comes here. Neither
duplicates the other.

# Chunks, and how they merge

One file per manager section, numerically prefixed so the order is explicit:

```
docs/manager-ui-guide/NN-<section>.md
```

Build the whole thing as one branded document with the pandoc pipeline, which
takes ordered inputs:

```bash
md-to-pdf --order-alpha docs/manager-ui-guide/*.md
```

The chunked-plus-merge shape is for maintainability: a section changes when its
page changes, and one file moves rather than a monolith gaining a conflict every
time two people touch it.

# The coverage rule, enforced

**Every item in the manager navigation has an entry here.**

That is not a promise anybody has to remember: `t/lint/32-manager-guide-covers-the-nav.t`
reads the nav out of `starter/lazysite/manager/layout.tt`, reads the items out of
these chunks, and fails when they disagree. A new menu item cannot ship without
a guide entry, and a retired one cannot leave a stale entry behind.

If an item genuinely should not have a walkthrough, say so in its chunk with an
`Intentionally omitted:` line and the reason. The lint accepts that and the next
reader learns it was a decision rather than an oversight.

## Dismiss buttons: Cancel and Close

One convention, everywhere in the manager (SM502 U-3):

Cancel
: The panel holds edits that have not been saved -- a row editor, a
  descriptor editor, a staged import. Cancel discards them. Clicking outside
  a modal editor, or pressing Escape, is Cancel.

Close
: The panel has nothing to discard -- a viewer, a report, a plan you have
  read. Close simply dismisses it.

A dismiss button that says Close on a panel with unsaved edits is a Cancel
wearing the wrong name; fix the label, not the behaviour.
