---
id: SM929
title: "SM929: every submission records the proxy's address, not the visitor's"
subtitle: "`_ip` reads 10.2.30.177 on all nine stored enquiries on a customer site - a private RFC1918 address, the front proxy. The field that exists to identify where a submission came from identifies our own infrastructure, identically, on every row, on every site behind the proxy. An address that is always the same is worse than no address, because it looks like information."
brand: plain
standard-margins: true
status: candidate
raised: 2026-09-30
raised-by: site agent, while assessing whether nine stored enquiries were genuine (0.15.0)
area: forms
---

# Measured

Nine enquiries on a customer site, 13 to 28 September, from at least two different
organisations and six unrelated spam campaigns. Every one records:

    "_ip": "10.2.30.177"

A private address. The site resolves publicly to a different address, so
10.2.30.177 is the front proxy talking to the application. The same value appears
on test submissions to edge.explore, and a second customer site records its own
proxy address the same way on every row of its contact store.

So `_ip` is **constant across every submission a site will ever receive**.

**Grade: measured on three sites, one of them ours.** The reporter checked whether
the address was routable before drawing a conclusion, which is the step that
turned this from a finding about the traffic into a finding about the engine.

# What it costs

**Triage.** The reporter was asked whether nine enquiries were junk. A shared
source address across all nine is normally strong evidence of one origin; here it
is evidence of nothing, and they nearly reported it as a signal. An operator
without the habit of checking would reach the opposite conclusion about their own
traffic.

**Anything per-address.** The Submissions page shows the address. The bad-URL
blocker and the login rate limiter are both documented as working per address.
Whether they read the header separately has not been established - but if any of
them sees what the form handler sees, it is counting one address for the whole
world. **That is the part of this filing to measure first**, because a rate
limiter keyed on a constant is a different severity from a misleading column.

**Abuse handling.** An operator who wants to block or report a source has nothing
to act on.

# What it should read

The forwarded-for header the proxy sets, falling back to `REMOTE_ADDR` when there
is no trusted proxy in front. That needs the usual care and none of it is novel:

- take the **first** address in `X-Forwarded-For`, not the last;
- only when the immediate peer is a **trusted** proxy, which this install can know
  - the address is in the private ranges the engine already ships behind;
- and keep `REMOTE_ADDR` when nothing is trusted, so a directly-served site is
  unaffected.

A forwarded-for header is caller-supplied, so the trust check is the whole
security of it: reading the header unconditionally would let any visitor write
whatever address they liked into the store, which is worse than the present state
rather than better. The engine already has a trusted-proxy notion for the
`auth_proxy_trusted` read that 0.15.1 restructured - whether it is the right one
to reuse here needs checking rather than assuming.

The anonymisation the stats plugin applies at write time is the model for what to
do with the result: the visitor log anonymises on the way in, and the submission
store could do the same rather than storing a raw address.

# Why it is worth doing rather than dropping the field

An address that is always the same is worse than no address: it looks like
information. A reader of the Submissions page sees a column of identical values
and concludes something about their traffic. Either the field carries the visitor,
or it should not be shown.

# How it was found

Assessing whether a customer's nine stored enquiries were genuine. Six were
commercial spam and three were real - one of them a production support case naming
a systemd exit status, unanswered for sixteen days because the form has no
delivery beyond local storage. The address field was the first thing reached for
to tell the campaigns apart, and it could not.

# Related

[[SM216]] (the quarantine scoring that runs on the same submission), [[SM930]]
(the own-domain rule, from the same nine submissions), [[SM925]] (why those nine
sat for sixteen days),
[[reference_lazysite_stats_gotchas]], [[feedback_uniform_field_not_constant]].
