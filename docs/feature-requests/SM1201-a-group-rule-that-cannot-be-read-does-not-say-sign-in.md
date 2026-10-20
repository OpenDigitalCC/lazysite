---
id: SM1201
title: "SM1201: a group rule that cannot be read does not say sign in"
subtitle: "A bare auth_groups value is still refused to everyone, now in a plain sentence that names no key and no group, as SM1189 did for addresses."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-19
raised-by: SM1189, "Left open" (from inbox/2026-10-19-test-plan-01510-results.md, finding F-2)
area: auth
status-note: "SHIPPED (PENDING) on n690: lazysite-processor/auth.pm (unreadable_rule), starter/lazysite/templates/system/403.md; t/integration/298."
---

# What happened

SM1189 gave a bare `addresses:` value the address sentence instead of "You need to
sign in to view this page", and left this open:

> Left open: a bare `auth_groups` still refuses with the sign-in sentence; that
> refusal is not an address one and was not part of the finding.

The walk's note (F-2) was written of both: "`addresses: zz60-mine` (not a YAML
list) refuses the page to everyone with 'You need to sign in to view this page',
including a signed-in member. It is the `auth_groups` rule ('a value that is not a
list refuses the page to everyone'), but the sentence sends a reader to sign in,
which cannot help." `auth_groups: staff` did exactly that.

# What shipped

- When the access keys the engine cannot read are only address and group rules
  (`addresses`, `addresses_deny`, `auth_groups`), and at least one is a group rule,
  the refusal reason is `unreadable_rule` and the sentence is "This page is not
  available." SM1189's choice is followed: one plain sentence, naming no key and no
  group, sending nobody to a sign-in that cannot help; the author is told by the
  validator and `lazysite check`, the visitor is not. Address-only stays the
  SM1139 address sentence.
- The shipped 403 page has the branch; the bare fallback page says the sentence; a
  site's own older copy of the 403 page has the sentence put in after its heading,
  as for the address sentence.
- Still refused to everyone, signed in or not (fail closed, SM980). A page whose
  unreadable keys include `auth` or `payment` (for example `auth: manager` on a
  content page) keeps its existing refusal: a sign-in or a payment is what that
  page was asking for.
- The validator's message already tells the author how to write it: "has the value
  'staff', which could not be read as a list - write it as a list: auth_groups:
  [editors], or one "- editors" line per group below it" (SM1189); unchanged.
- `t/integration/298` runs the processor on a bare `auth_groups` (alone, and with
  an address rule), with the shipped 403 page and with an old site copy, and holds
  the controls.
