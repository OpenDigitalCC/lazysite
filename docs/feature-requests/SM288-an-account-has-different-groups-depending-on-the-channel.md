---
title: "SM288 - The same account has different groups depending on which channel it arrives on"
subtitle: "WebDAV resolves a partner's real groups, so an @group ACL matches it. MCP hard-zeroes them and the control-API token path never receives them. One store, one question, three answers."
brand: plain
status: candidate
status-note: "FILED 2026-08-12. The operator corrected me: 'Token/MCP/WebDAV partners do have groups applied, and I expect would work in the same way.' They were right for WebDAV and I had said otherwise, repeating a comment in Lazysite::Auth::Acl that is itself wrong. MEASURED: a WebDAV partner in @editors is served a file gated to @editors, and refused after the group is removed - so the match is the group, not an operator bypass. Probe at tmp/partner-groups-probe.t, 5 assertions. NOT STARTED."
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

## Related

[[SM224]] (the analysis that carried the error as a headline finding),
[[SM223]], [[SM279]] (one resolver, not two - the pattern to follow),
[[SM268]] H4/H8/H13/H15 (two surfaces disagreeing about one question, the
recurring theme this belongs to), and `t/lint/17-dav-shared-parity.t` as the
model for the lint.
