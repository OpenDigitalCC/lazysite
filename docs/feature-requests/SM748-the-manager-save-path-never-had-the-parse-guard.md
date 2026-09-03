---
id: SM748
title: "SM748: the manager save path never had the parse guard, and the test that says otherwise counts two of three"
subtitle: "WebDAV refuses an unparseable body with 415. The manager's action=save accepts it with ok:true. SM708 wrote down that the manager was unguarded; SM729 closed the WebDAV half and nobody closed the other. The test asserting both stacks enforce it reads two files and neither is the control API."
brand: plain
standard-margins: true
status: shipped
---

# The finding

From the field agent, on 0.12.1. The same body through two routes:

    ---
    title: g
    ---

    unmatched [% END %]

- **WebDAV PUT** - `415`, refused.
- **Manager `action=save`** - `200 {"ok":true}`, accepted, and the saved page
  renders the raw fallback, so `[% END %]` appears literally on the page.

`action=save` is not a secondary route. `/manager/edit?path=...` saves through
exactly `fetch(API + '?action=save&path=' ...)`, so this is **the primary
editing path** for a human operator.

# It is not a regression, and that is worse

They asked the right question - never covered, or regressed? The source answers
it, and so does SM708's own status note, written when it shipped:

> the check covers MCP writes ONLY - the manager UI editor and WebDAV do not
> call `_validate_page`, so a page written through either is unguarded.

So SM708 **knew** two callers were unguarded and said so. SM729 was then filed
as "the write-parse guard does not reach the WebDAV stack", named WebDAV, fixed
WebDAV, and closed. The manager half of SM708's own sentence was never picked
up.

Nothing broke. A known gap was half-closed, and the half that stayed open is the
one an operator actually uses.

# Why nothing caught it

`t/unit/manager/141` is titled *the page-parse guard reaches both write stacks*
and its subtest is *both write stacks consult it*. It reads two files:
`lazysite-dav.pl` and `lazysite-mcp.pl`. It never opens
`lazysite-manager-api.pl`.

The name is defensible under SM430's finding that there are **two write stacks,
not four** - the manager UI, control API and MCP share `lib/Lazysite/Manager/*`
while WebDAV re-implements the chain. But the guard is **not in the shared
module**. It is called inline from `lazysite-mcp.pl`, which is one caller on
that shared stack, not the stack itself. So "both stacks consult it" is checked
by reading one member of each group and assuming the group.

**Three callers write pages. Two consult the guard. The test asserts a property
of stacks and verifies it on files.** That is how a green test coexists with an
unguarded primary path for two releases.

# What shipped

All three: the instance, the class and the test.

**The guard moved to the choke point.** `page_parse_refusal` is now called from
`Lazysite::Manager::Files::action_save`, beside SM189's `raw_html_page_refusal`
- which had already solved this exact problem correctly, and whose comment says
so: *"Because MCP write_file / create_page route through action_save, this
covers the manager save AND MCP; the WebDAV PUT path enforces the same guard in
lazysite-dav.pl."* SM708 had the pattern available and put its guard in a caller
instead.

So the manager, the control API and MCP are all covered by one call, and only
the separate WebDAV stack keeps its own - which is the shape SM430 describes:
two write stacks, not four.

**The three inline copies are gone.** `lazysite-mcp.pl` no longer calls the
guard or defines its `_page_parse_refusal` wrapper; all three call sites sat
immediately above an `action_save` that now carries the rule. Leaving them would
have put one rule in two places, which is how the two could later disagree.

`page_parse_issues` survives in MCP, because `_validate_page`'s use of it is
**advisory** - a validator reports, a write refuses, and those are different
jobs.

**The guard now has exactly two call sites in the tree.** The choke point, and
the DAV stack.

## The test that would have caught it

`t/unit/manager/141` was titled *reaches both write stacks* and opened two named
files, neither of which was the one at fault. It now **walks the tree** and
asserts the set of call sites is exactly `{Files.pm, lazysite-dav.pl}`.

A fourth surface therefore has two options: route through `action_save` and
inherit the guard, or add a third call site and fail this test - which is the
conversation worth having.

**Mutation-checked.** With the guard removed from `action_save`, the new 141
fails. The old 141 passed in exactly that state, for two releases.

`t/unit/manager/151` adds the behavioural half, because a guard in the right
place that does not fire is the same defect with a better address: an
unparseable body is refused with `kind: template-parse-refused` and **nothing
lands on disk**, while a page that parses, and a `.txt` carrying the same bytes,
both still save.

`t/unit/manager/140` moved with the guard - it now asserts MCP carries no
private copy, rather than asserting the three inline guards that were the
defect.

## Impact, for the record

Assessed before deciding whether to patch or wait, and recorded because the
answer was less alarming than the defect sounds.

**Not a security issue in any direction.** An unparseable page renders through
the raw fallback, which means Template never interpolates - so variables appear
literally as `[% auth_user %]` rather than resolving. It fails towards showing
less, not more. No escalation, no data exposure, no loss: the page saves, it is
merely wrong, and it can be edited again.

**Self-announcing.** A page with every variable dead is visibly broken to
whoever next looks at it. This is not a silent corruption; it is a loud one.

**Rare in practice, and measured rather than assumed.** SM744 counted 495
markdown files carrying `[%` across every reachable tree: **two** fail to parse,
and both are CHANGELOGs, which nobody saves through the manager.

**But it does happen** - SM708 exists because it happened in the field: a
literal `[%` in page JavaScript, which is easy to write by accident and blanks
every substitution on the page.

**It had been live for four releases** (0.11.10 through 0.12.1) with no field
report of it biting, which is itself evidence about frequency.

The conclusion drawn: **low severity, low urgency, no emergency patch**. It
belongs in the next planned cut. Holding a release for it would have been
disproportionate, and shipping 0.12.1 without it made nothing worse than the
four releases before.

# The fix, and the wider fix

**The instance:** `lazysite-manager-api.pl`'s `save` consults
`page_parse_refusal` before writing, refusing in the house shape with the same
message the other two give. SM708's own reasoning applies unchanged - it must
refuse *before* the write, not as an advisory issue attached afterwards, because
by then the page is on disk.

**The class, which matters more:** the guard belongs in the shared write path
rather than in each caller, so a fourth caller inherits it instead of having to
remember it. Where exactly is a design question - `Lazysite::Manager::Common`
already holds the refusal, so the missing piece is a single choke point that
every page write passes through, which is CF-2's territory in [[SM430]].

**And the test earns its title or loses it.** A check that enumerates **every**
caller that writes a page and asserts each consults the guard - derived from the
tree rather than from a hand-written list of two filenames - is what would have
caught this. A hand-listed test can only ever be as complete as the day somebody
wrote the list.

# What this says about SM744, filed one day earlier

The two findings are the same measurement failure pointing opposite ways.

SM744: the guard **refused pages it should have accepted** - five of seven, all
real pages - because nobody had counted what it met.

SM748: the guard **accepts pages it should refuse**, on the primary editing
path, because nobody had counted who called it.

Both were invisible to a green suite. Both were found by running the real thing
from outside. The reach of a guard is not a property anybody had measured in
either direction.

# Provenance

Field agent, 0.12.1 on edge, 2026-09-03, following their own SM744 verification
- the genuine-failure CONTROL in that test is what surfaced it, which is worth
noting: the control was there to prove the fix had not over-loosened, and it
found a different defect instead.
