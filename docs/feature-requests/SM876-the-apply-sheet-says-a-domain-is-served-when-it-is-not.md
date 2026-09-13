---
id: SM876
title: "SM876: the apply sheet's readiness warning could never fire, so an unpointed domain was reported as resolving and served"
subtitle: "It read `chk.dns.ok`, `chk.tls.ok` and `chk.vhost.ok`. domain-check returns an ARRAY of `{id,label,pass,detail}` with ids dns/host/ssl/terminates - no tls, no vhost, and the field is `pass`. Every lookup was undefined, `undefined === false` is false, and the warning branch was unreachable: the green tick rendered unconditionally for every host that ever reached it."
brand: plain
status: shipped
raised: 2026-09-13
raised-by: site agent (tier-B B6)
area: manager-ui, domains
---

# What was found

The site agent, walking **tier-B B6** - *a readiness warning on an unpointed
target* - did the thing the check is for: added a domain that genuinely does not
resolve, confirmed it with the engine's own checker, then selected it as the
apply target.

`domain-check` on `notpointed-1315b.example.com`:

```text
dns          pass=0   the host name does not resolve yet - add the DNS record
host         pass=0   skipped - the host does not resolve
ssl          pass=0   no trusted HTTPS
terminates   pass=0   no reply over HTTPS - Could not connect ... :443
```

The apply sheet, about the same host at the same moment:

> ✓ notpointed-1315b.example.com is resolving and served.

In green, with a tick, naming the host - so it was computed for that target and
not left over from a previous selection.

Their reading, which is the right one:

> "That is worse than silence. A missing readiness line leaves an operator to
> check; a green tick tells them not to bother."

# Why - three mismatches, and the failure is open

`starter/manager/backups.md` read:

```javascript
if (chk.dns   && chk.dns.ok   === false) probs.push('DNS does not resolve here');
if (chk.tls   && chk.tls.ok   === false) probs.push('no valid TLS certificate');
if (chk.vhost && chk.vhost.ok === false) probs.push('no vhost is serving it');
```

`Lazysite::Manager::Domains::domain_check` returns:

```perl
return { ok => 1, host => $host, all_pass => $all_pass, checks => \@checks };
#   @checks = ( { id, label, pass, detail }, ... )
```

- **`checks` is an ARRAY, not a map.** `chk.dns` is undefined even for the ids
  that exist.
- **`tls` and `vhost` are not ids the engine emits.** They are `dns`, `host`,
  `ssl`, `terminates`.
- **The field is `pass`, not `ok`.**

So every lookup was `undefined`, and `undefined === false` is **false**. `probs`
could never be populated. **This is not "the warning did not fire for this
host" - the branch was unreachable and the tick was unconditional**, for every
host, since the readiness block shipped.

The failure direction is the bad one: a wrong field name failed OPEN, into an
assurance, rather than closed into a warning.

# The fix, and the third state it has to respect

The block now walks `chk.checks`, and reports a failing check using **the
engine's own `label` and `detail`** rather than three strings invented in the
page - one place says what a failing check means, and it is the place that ran
it.

**`pass` is 1, 0 or NULL, and the null is deliberate.** From `Domains.pm`:

> "Behind a proxy or NAT the server cannot know its own public IP, so when none
> was discovered this is INDETERMINATE (undef), not a failure."

A two-state reading has to get one of those wrong: treating null as failed warns
on every proxied site, and treating it as passed asserts reachability nobody
established. So there are three outcomes now - a warning listing definite
failures, the green tick **claimed only when the engine says `all_pass`**, and a
neutral line naming what could not be confirmed.

# The test, and why it is a lint

`t/lint/140`. Nothing executes this JavaScript: `t/lint/136` renders each manager
page and parses its scripts, so a syntax error is caught and **a wrong field
name is not** - the page is valid JavaScript reading keys that are not there.

The defect is a **disagreement between two files**, which is what a lint is for -
the same shape as `t/lint/58` (the action reference against the dispatch chain)
and `t/lint/81` (the capability list against its copy). It extracts the ids
`domain_check` actually emits and asserts the sheet reads those, reads `pass`,
distinguishes null from 0, and takes the tick from `all_pass`.

Verified against the defect rather than only against the fix
(`tmp/prove-lint140-catches-b6.sh`): **seven of its thirteen assertions fail** on
the code as it shipped.

# Worth noting

Four releases of a green tick that could not be anything else, found by a person
deliberately pointing the feature at a domain that does not work. No test could
have caught it, because both files were internally correct and neither knew about
the other - which is precisely the gap the manual-check tiers exist to cover, and
the first thing tier B has caught since it was written.

# Related

[[SM874]] (the other tier-A/B finding from the same walk),
[[feedback_a_declaration_the_code_ignores]] (find every reader),
[[feedback_a_boolean_has_four_states]] (the indeterminate `pass`),
[[feedback_verify_the_gate_tests_what_you_think]].
