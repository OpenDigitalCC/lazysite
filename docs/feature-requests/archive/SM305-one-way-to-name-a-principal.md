---
title: "SM305 - Three ways to name a user or a group, and the most consequential one is a bare textbox"
subtitle: "Protecting a section asks who may read it as free text with no suggestions. Mistype a group and the section is gated to nobody, silently, and the operator is told it worked."
brand: plain
status: shipped
status-note: "SHIPPED in 0.10.10 (92248da). FIVE controls, not the three originally filed: the section sheet's bare text box, datalists on Groups, Users and Domains, and the per-file card's select which was already right. All five now use one shared mgPrincipalSelect built in the manager layout from one source. Deliberately no onchange on the Groups picker - selecting POSTs there and a select fires change while a keyboard user arrows through options; Files keeps its onchange because nothing is written until Save. t/lint/47 pins it, shown to fail on the pre-fix tree, with exemptions keyed by datalist id and reason (nav.md page-urls stays: a nav entry may point off-site). ORIGINALLY FILED: FILED 2026-08-15 from operator feedback. Nothing started. Two things in one filing because they are the same defect at two scales: the specific control that should be a select, and the absence of a single way to name a principal anywhere in the manager. Adding, modifying and deleting users and groups is one piece of functionality and is currently three."
---

# SM305 - the same job, three controls

## The specific defect

`starter/manager/files.md:514`, in the folder-protection card:

```html
<input type="text" class="mg-inp mg-sec-read"
       placeholder="alice, @editors (leave blank for nobody but you)">
```

**Who may read a protected section is free text**, with no suggestions and no
validation. The value is split and written straight into the ACL.

Type `@editrs` for `@editors` and the section is gated to a group that does not
exist. Nothing refuses it, nothing warns, and the confirmation says the section
was restricted - which it was, to nobody. The intended editors lose access and
the operator has been told the operation succeeded.

The failure is at least fail-CLOSED, so this is a usability and integrity defect
rather than an exposure. It is still the same shape this project keeps removing:
an operation that reports success without doing what was asked.

## The general defect

Three controls now exist for naming a principal, and they behave differently:

```datatable
columns: Where | Control | Behaviour
widths: 4.6cm | 4cm | X
bold: 1
tone: medium
text: 3
---
`users.md` | real `<select>` | Constrained. Only offers what exists
`groups.md` | `<input list="all-users-list">` | A datalist: suggests real principals, still accepts anything typed
`files.md` protect-section | bare `<input type="text">` | No suggestions, no constraint, no validation
```

The strictness runs in exactly the wrong direction. The loosest control governs
**who can read protected content**; the strictest governs an account's type.

Adding, modifying and deleting users and groups is one piece of functionality.
It should look and behave the same wherever it appears - not because consistency
is tidy, but because an operator who learns the control in one panel currently
learns nothing transferable, and because two of the three let them name
something that is not there.

## What to build

One principal picker, used everywhere a user or a group is named:

- offers the real users and groups, grouped and labelled so `@group` and `user`
  are visually distinct;
- accepts multiple values as removable pills, matching the token control
  `groups.md` already uses for members - that pattern is right and should be the
  one that spreads;
- **refuses a name that does not resolve**, or accepts it only behind an
  explicit "add anyway" for the case where an account is about to be created;
- is one component, so a fix or an affordance added once appears everywhere.

Then apply it to the protect-section read list, the per-file ACL editor, group
membership and any future panel that names a principal.

## Care needed

- **Resolution must be a real check, not a client-side list.** The picker's
  suggestions come from a list the browser was handed; the refusal has to be
  server-side, or it is advice rather than a guard. `acl-set` already knows what
  exists.
- **Do not break the blank case.** An empty read list means "nobody but you" and
  is a legitimate, deliberate choice. A picker that demands a value would remove
  it.
- **A group that is later deleted still leaves a stale name in a stored rule.**
  This filing does not solve that; `lazysite check` reporting rules that name
  principals which no longer exist is the natural companion and is worth
  considering alongside.

## Related

[[SM267]] (which added the protect-section card), [[SM289]] (one way to express
access on every surface - this is the same argument applied to the UI rather
than the API), [[SM279]] (a stored value that was never enforced, and the check
that found it).
