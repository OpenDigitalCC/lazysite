---
id: SM702
title: A capability held through nesting was never granted, because a slurp leaked
raised: 2026-08-31
raised-by: release manager
area: auth
status: shipped
status-note: "SHIPPED (unreleased; lands in 0.11.9). `local $/` in _groups_grant_cap is scoped to the enclosing BLOCK, which was the whole sub - so it was still undef when _group_closure ran below it. _group_membership_map reads the groups file with `while (<$fh>)`, and in slurp mode that loop takes the ENTIRE FILE as one line: measured on the shipped store, the map collapsed from 21 groups to 1, the parent table came out empty, and NO nested group ever resolved. The shipped groups are arranged by nesting - ch-ui contains site-admins, content-editors and the rest - so an account in site-admins was told 'Manager access not permitted'. It fails CLOSED, a lockout rather than a leak. The slurp is now scoped to a block. t/unit/auth/60 grants a capability ONLY through nesting and fails on the unfixed code."
---

# What the operator saw

> it initially signed me in, then http://ai-dev:8412/manager
> **Manager access not permitted.** You are signed in to My Site as manager,
> but this account is not permitted to use the manager interface.

The account was in `site-admins`. The shipped groups file puts `site-admins`
inside `ch-ui`, and `ch-ui` is the group that holds `ui`. Every link in that
chain was correct in the stores, and the answer was still no.

The two-step appearance - signed in, then refused - is two different steps:
the login succeeded and redirected, and the manager gate refused on the next
request.

# The cause

`_groups_grant_cap` reads the settings file like this:

    open my $fh, '<:raw', $f or return 0;
    local $/;
    my $gs = eval { JSON::PP::decode_json(<$fh>) } || {};
    close $fh;
    for my $g ( _group_closure(@groups) ) { ... }

`local $/` is scoped to the enclosing **block**. There is no block here, so it
is the whole subroutine - and it was still `undef` when `_group_closure` ran on
the next line. That function's `_group_membership_map` reads the groups file
with `while (<$fh>)`, which in slurp mode takes the entire file as **one line**.

Measured on the shipped store:

| `$/` | groups parsed |
| --- | --- |
| normal | 21 |
| slurp (leaked) | 1 |

With one group in the map the parent table is empty, so the closure returns
only the groups it was given. Nesting stops existing.

# Why it survived

**It fails closed.** A lockout, not a leak: no capability is granted that
should not be. That makes it a usability failure rather than a security one,
and it means nothing alarming happened to draw attention.

**Every existing test put its user in a group that holds the capability
directly.** That path never calls the closure for a result it depends on, so
the whole suite passed. The regression test therefore grants the capability
ONLY through nesting - and its fixture carries extra group lines, because a
two-line fixture would still work when only the first line survives.

**The functions look correct in isolation and are.** `_group_membership_map`
and `_group_closure` both pass when called directly; the test asserts that too,
and those two subtests pass even on the unfixed code. The defect exists only in
the caller's ambient state, which is why reading either function would never
find it.

# The fix

Scope the slurp to the read:

    my $gs;
    {
        open my $fh, '<:raw', $f or return 0;
        local $/;
        $gs = eval { JSON::PP::decode_json(<$fh>) } || {};
        close $fh;
    }

# A note on how it was found

The first diagnostic printed the closure at the TOP of the sub - above the
`local $/` - and showed a correct closure, which pointed away from the real
cause. The instrument was in the wrong place to see the thing it was measuring.
Worth remembering: a probe that runs before the suspect line proves nothing
about the line.

# Related

[[SM121]] (compound group expansion - the feature this silently disabled),
[[SM420]] (`local $_` for the same class of leak in the same function, which
suggests the hazard was known here and the sibling case was missed).
