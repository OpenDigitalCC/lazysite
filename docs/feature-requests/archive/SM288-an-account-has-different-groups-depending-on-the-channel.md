---
title: "SM288 - The same account has different groups depending on which channel it arrives on"
subtitle: "WebDAV resolves a partner's real groups, so an @group ACL matches it. MCP hard-zeroes them and the control-API token path never receives them. One store, one question, three answers."
brand: plain
status: shipped
status-note: "SHIPPED on main (unreleased) 2026-08-12, phase 1 item 2 of WORK-PLAN-ACCESS-CONTROL. ONE resolver - Lazysite::Auth::Acl::groups_for_user, delegating to Settings::effective_groups, which is what the capability and domain-access resolvers already use - called by all three channels. MCP no longer hard-zeroes; the control API resolves from the ACCOUNT for a token client and keeps X-Remote-Groups for a cookie client, whose session sets it; WebDAV's own group-file parser is DELETED rather than left beside the shared one (SM279's lesson: a second answer is a disagreement waiting to happen). t/integration/44 is a MATRIX - one question asked on every channel that can answer it, then the group removed and asked again, because 'allowed everywhere' is only half of consistent; plus a named-partner control and a nested-group case. t/lint/35 pins the shape and catches the fourth channel somebody adds. Verified failing on the stashed tree: MCP fails both group cases while WebDAV passes either way (the control proving the test is not just detecting a broken tree), and 8 of 11 lint assertions fail. TWO FINDINGS while building it, both recorded below: the control API has NO token action that makes a per-file read decision, and lazysite-check now reports which @group entries exist because this change WIDENS access on upgrade."
---

# SM288 - one account, three group memberships

## What is true

| Channel | Where the ACL's `@user_groups` comes from | `@group` matches a partner? |
|---|---|---|
| **WebDAV** | `user_groups_for($user)` - the account's real groups, from the group file | **yes** |
| **MCP** | hard-set to `()` | no |
| **Control API (token)** | `HTTP_X_REMOTE_GROUPS`, which a token client does not carry | no, in practice |
| Manager (cookie) | `HTTP_X_REMOTE_GROUPS`, set by the auth wrapper from the session | yes |

So the same partner account, in the same group, reading the same file under the
same ACL, is **allowed over WebDAV and refused over MCP**.

## How it was found, and why that matters

Not by a test and not by a review. The operator read a summary I had written -
that partners carry no groups - and said plainly that partners do have groups
and they would expect `@group` to work the same way for them.

They were right, and my claim came from repeating this comment in
`Lazysite::Auth::Acl`:

> `# A token/WebDAV partner carries none, so a @group entry never matches it`

which is **false about WebDAV**, sitting directly above the variable it
describes. It had also been copied into `docs/architecture/access-control-model.md`
as a headline finding, where it survived the SM224 analysis, the SM223 work and
an adversarial security review.

**A wrong comment next to correct code outlives a wrong line of code**, because
nothing executes it and every reader trusts it. That is the transferable lesson
here, and it is the second time in two days that reading rather than running
produced a confident wrong answer (the first was `^~` in SM283).

## Which behaviour is right

The operator's expectation is the design intent: **a group is a property of the
account, not of the door it came through.** WebDAV is correct; MCP and the token
path are the defect.

The counter-argument, from the original comment, is that zeroing is "the safe
default" - a partner cannot inherit access it was not explicitly given. That has
force for a *capability*, which is why the capability model resolves groups
separately and correctly on every channel. It has much less force for a read
ACL, where the operator has deliberately written `@editors` and expects it to
mean the editors. And it is not even applied consistently as a safety measure,
since WebDAV - the channel that writes files - already honours it.

## What to build

Resolve the authenticated account's real groups on every channel, the way
WebDAV already does.

- MCP: replace `@user_groups = ()` with the account's resolved groups.
- Control API: for a token client, resolve from the account rather than from
  `HTTP_X_REMOTE_GROUPS`, which is a cookie-path mechanism that a token client
  structurally cannot populate. The header must remain the source for cookie
  clients and must stay untrusted-by-default (the SM-era trust gate is
  unaffected).
- One resolver, called by all three, so this cannot drift again - the same
  shape SM279 used when it deleted the second answer rather than fixing it.
- A lint that asserts every channel assigns `@user_groups` from that resolver,
  in the manner of `t/lint/17` (dav/shared parity).

## Care needed

**This widens access on live sites.** An `@group` ACL that has been silently
inert for MCP partners starts applying the moment this ships. That is the
intended behaviour and it is still a change of effective permissions, so it
belongs in a release note under its own heading, not in a list - and
`lazysite-check` should be able to report, before the upgrade, which entries
would begin matching which partners.

The reverse risk is worth stating too: nobody should read this filing as
"partners gain groups". They have them; two channels were discarding them.

## The release note and the pre-report, done 2026-08-19

Both things "Care needed" asked for now exist:

- `UPGRADE.md` carries the widening under **its own heading**, stating
  that nobody gains groups - partners had them and two channels were
  discarding them.
- `lazysite acl group-reach` lists each `@group` entry, the paths
  granting it, and every account it reaches **including through nested
  groups**.

It lives in the ACL tool rather than `lazysite-check` deliberately.
That tool is core-Perl by design and resolving membership there would be
a fourth answer to "which groups is this account in" - the defect this
filing exists to remove. Reporting direct membership only would be worse
than not reporting: it would tell an operator that somebody does not
gain access when they do. `groups_for_user()` is the one resolver every
channel now uses, so the report is wrong only if the engine is wrong,
which is the only safe direction.

## Acceptance

- The same partner account, in the same group, gets the same read decision on
  WebDAV, MCP and the control API.
- Removing the account from the group refuses it on all three.
- A partner named explicitly in a list is unaffected on all three.
- The probe at `tmp/partner-groups-probe.t` becomes a real test covering all
  three channels rather than WebDAV plus source assertions.
- The comment in `Lazysite::Auth::Acl` and the architecture doc agree with the
  code - both are corrected already, ahead of the fix, because a wrong comment
  is what caused this.

## Two findings from building it

**The control API has no token action that makes a per-file read decision.**
Both `read` and `file-download` answer *"served only to the manager UI over a
cookie session"*. So a token client can **set** an ACL there and cannot read the
content it just governed - it has to change channel, to MCP or WebDAV, to
exercise the grant it wrote. That is why the behavioural matrix covers WebDAV
and MCP (the two channels that used to disagree) and the control API's half is
pinned at source: there is no behaviour to drive. Recorded for [[SM289]], whose
"same method from every surface" turns out to have a bigger hole than the two
names it was filed about.

**The upgrade preview could not be built honestly, so it was not.**
`lazysite-check` now lists the `@group` entries and says plainly that they apply
on every channel from this release. It deliberately does **not** list who is in
each group. The options were: duplicate the closure logic (a fourth answer to
the question this filing exists to give one answer to), report direct membership
only (which omits anyone in a nested group, telling an operator that somebody
does **not** gain access when they do), or name the entries and point at the
tool that knows - `lazysite-users.pl groups`. This file is core-Perl by design
and cannot load the resolver. **Under-reporting who gains access is worse than
not reporting it**, so the third option won.

## Related

[[SM224]] (the analysis that carried the error as a headline finding),
[[SM223]], [[SM279]] (one resolver, not two - the pattern to follow),
[[SM268]] H4/H8/H13/H15 (two surfaces disagreeing about one question, the
recurring theme this belongs to), and `t/lint/17-dav-shared-parity.t` as the
model for the lint.
