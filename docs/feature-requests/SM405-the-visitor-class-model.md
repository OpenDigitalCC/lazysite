---
title: "SM405: seven visitor classes, and behaviour over declaration"
subtitle: "Five classes conflate three different questions an operator asks. The substantive split is that an assistant fetching a page because a person asked is a visit, and a training crawler is not - today both land in `ai`, which makes the class unusable for either purpose."
brand: plain
standard-margins: true
status: candidate
status-note: "DECIDED 2026-08-19, NOT BUILT. Two decisions taken together, both from the visitor-classes briefs: (1) the model moves from five classes to SEVEN - human, ai-agent, ai-crawler, search-crawler, agent-declared, probe, noise; (2) where a DECLARED identity and OBSERVED behaviour disagree, behaviour wins. Recorded as a filing rather than started, because it changes the meaning of stored day files and wants its own basis stamp under SM338 - the aggregates carry counting_basis and classifier_version precisely so a reader can tell a change of rules from a change of traffic, and this is the change those fields exist for. NOT a beta blocker: the current five classes are wrong in a way that understates nothing an operator relies on today, and SM391 already made the rulesets loadable data, which is where most of this lands."
---

# Why five is the wrong number

The five conflate three different questions. Splitting by *why an operator
cares*:

| Class | What it is | In scope by default |
|---|---|---|
| `human` | A person, to the best of detection | yes |
| `ai-agent` | An AI acting FOR a person - an assistant answering a question | yes |
| `ai-crawler` | Training or index ingestion - GPTBot, CCBot, ClaudeBot | no |
| `search-crawler` | Googlebot, Bingbot and friends | no |
| `agent-declared` | Self-identified tooling: partner agents, monitoring | no |
| `probe` | Vulnerability sweeps, path guessing | no |
| `noise` | Missing favicons, robots.txt, broken clients | no |

::: widebox
**An assistant fetching a page because a person asked it something is a visit.
A training crawler is not.** Today both land in `ai`, so the class answers
neither question - an operator cannot tell demand from ingestion, and those
prompt opposite decisions.
:::

`agent-declared` is separate from `bot` on purpose. It is the only class whose
membership can be **known** rather than inferred, and it is currently mixed into
both `bot` and `human`.

# Behaviour beats declaration

A declaration is a claim anyone can make; probing is evidence.

If a declared identity could override observed behaviour, the `agent-declared`
class would be an **opt-out for attackers** - a User-Agent string that buys its
way out of `probe`. So where the two disagree, behaviour wins, and a token that
probes is classified on what it did whatever it calls itself.

This is already the shipped behaviour, by way of SM392's promotion. What this
records is that it is a **decision** rather than an accident, so a future change
has to argue against it.

# Why this is filed rather than started

It changes what a stored day file MEANS. [[SM338]]'s `counting_basis` and
[[SM391]]'s `classifier_version` exist exactly so a reader can tell a change of
rules from a change of traffic - this is the change those fields were built for,
and it needs the basis bump, the migration note, and a decision about whether
old days are re-derived or left on their old basis.

[[SM391]] already made the rulesets loadable data rather than code, which is
where most of the implementation lands.

# Not a beta blocker

The current five are wrong in a way that **understates nothing an operator
relies on** - the error is that two different things share a bucket, not that a
number is inflated. Beta can ship on five.
