---
title: "SM649: a preview cookie does not bypass authentication, an ACL or a draft flag - and nothing in the suite would notice if that stopped being true"
subtitle: "Site agent, 2026-08-26: `preview-grant` discloses nothing, the mechanism is correct, and the property holding it up is call ordering inside one sub with no test on it"
brand: plain
standard-margins: true
status: shipped
status-note: "FIXED, and the headline was a proved negative: preview-grant discloses nothing and the mechanism is unchanged. What was missing is now built - t/integration/52 mints a REAL preview cookie (true HMAC over the real payload against the site's own secret, because a faked cookie measures the signature check rather than the gate ordering) and proves it opens neither `auth: required` nor an ACL. It first proves the cookie was HONOURED, via the no-store marker, so a refusal cannot be a rejected cookie doing nothing. Three sabotages, all fail, including one that makes check_preview return undef - the vacuous-test guard. THE FLAG IS CORRECTED IN BOTH DIRECTIONS with SM647: preview-grant and preview-clear leave %CHANGES_ACCESS, because the test now shows what the inaccurate comment claimed is false - a preview overrides layout and theme, and moves no read boundary."
---

# What is NOT wrong, recorded first

`preview-grant` discloses no content. A preview cookie does not bypass
`auth: required`, does not bypass an ACL rule, and does not reveal a draft. The
stop is structural rather than incidental, and the ordering is the right
design.

That is stated first and plainly because it is the part most easily lost. A
filing titled after a preview grant will be read by someone in a hurry as an
access hole, and it is not one. **The mechanism should be left exactly as it
is.**

# What is wrong: nothing defends it

The property holds because `check_preview()` is called below the auth gates,
inside one sub. That is a true fact about today's source and nothing more:

| Test | What it covers | Auth / ACL assertions |
|---|---|---|
| `t/unit/manager/09-preview-grant.t` | mint, verify, render, CSRF, bad layout/theme, `no-store` | none |
| `t/integration/06-preview.t` | three assertions | **none** |

A refactor that moves `check_preview()` above the auth check, or hoists preview
context into an earlier resolution step, converts this from safe to a
content-disclosure hole **with the whole suite green**. Nobody would be careless
to make that change; the ordering carries no marker saying it is load-bearing.

This is the difference between a property that is true and a property that is
defended, and it is the whole of this filing's value.

# The declaration, which is the cheap half

`%CHANGES_ACCESS` states its own test: *does the call alter who may read?*

| Action | Flag | Alters who may read? | |
|---|---|---|---|
| `domain-set` | absent | **yes** - writes `allowed_groups` | under-flagged (SM647) |
| `preview-grant` | true | no | over-flagged |
| `preview-clear` | true | no | over-flagged |
| `acl-set` / `acl-remove` | true | yes | correct |

Under-flagging hides a real access change from every audit surface.
Over-flagging points a reviewer at a door that is not there and spends the
credibility of the flag - which is part of why SM647 was easy to miss. The two
are the same table read in opposite directions and are worth fixing in one pass,
because a reviewer checking the table against the mechanism meets both.

# The audit gap

A successful `preview-grant` writes nothing to the audit trail: dispatch exits
before the `audit_log` call, and the action is also listed in `%skip` - two
entries SM516 (MA-15) already flags as dead. Only a manager-log `log_event`
records it.

Whatever is decided about the flag, minting a token that affects a session
should leave a trail. An action published as `changes_access: true` that writes
no audit row has its flag and its trail disagreeing with each other as well as
with the mechanism.

# In priority order

1. **A regression test that a valid preview cookie does not bypass
   `auth: required`, an ACL rule, or a draft flag.** Three assertions. The
   invariant stops being accidental. Worth more than everything below.
2. Remove `preview-grant` / `preview-clear` from `%CHANGES_ACCESS` and correct
   the comment above it - two lines, and it closes the mirror of SM647.
3. Audit successful `preview-grant` / `preview-clear`; overlaps SM516 MA-15.
4. **Leave the mechanism alone.** Only the declaration, the trail and the test
   coverage need work.
