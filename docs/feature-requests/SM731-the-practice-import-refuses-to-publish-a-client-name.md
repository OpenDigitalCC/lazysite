---
id: SM731
title: "SM731: the practice import refuses to publish a client's name"
subtitle: "starter/docs/ai-briefing-practice.md ships inside every lazysite installation and is built from field notes written on real client sites. The import now refuses when the assembled document names one, because the natural way to make a field point is to name the site it was learned on."
brand: plain
standard-margins: true
status: shipped
---

# The exposure

`tools/import-field-practice.pl` assembles the shipped practice briefing from
two documents in the site agent's trees. **That briefing is installed on every
lazysite site.** The sources are field notes from real client work, so the most
natural way to make a point in them is to name the site it was learned on.

The 2026-09-02 update did exactly that, three times. One is materially worse
than the others:

> `community.dhcf.eu` writes a three-number stats panel as 24 lines of hand HTML
> with an inline `style` hack. `dito.tech` renders the same shape from a 9-line
> component fed by a list.

**Two named client sites and a judgement about which is badly built**, headed for
publication to every installation. The other two are a client project named as
the origin of a ruling - less damaging, still published.

Nothing had shipped: `t/lint/89` failed because the sources no longer matched the
served copy, which is what put a person in front of it. That lint exists to catch
staleness; it caught this by luck rather than by design.

# The guard

The import refuses to write when the assembled document contains a client
identifier, naming the line and the match, and pointing at the source.

**At the import boundary, deliberately, and not in the source trees.** Those
documents belong to the site agent - the standing rule is that work outside a
tree goes to that tree's inbox, not into its files - and a check at the boundary
cannot be forgotten by whoever writes the next note. It is the same shape as
SM729 one day earlier: put the guard where every path reaches it.

## One thing the first version got wrong

A plain substring match flagged `dito` inside "e**dito**r", five times. Word
boundaries fixed it. Worth recording because a leakage check that cries wolf gets
switched off, and a list of short client names is unusually prone to it -
`jpm`, `dito` and `dhcf` are all substrings waiting to happen.

# What this does not do

**It does not redact.** It refuses, names what it found, and stops. Redacting
another agent's notes automatically would be worse than the exposure: the point
being made is theirs to preserve, and a machine rewrite would eventually mangle
one.

**It is a list, not a classifier.** It knows the identifiers on this estate and
nothing else. A new client is invisible to it until the list is updated, which is
a real limitation and is the reason to keep the list beside the guard where
somebody adding a client will see it.

# The state this leaves

The gate is red until the sources are redacted, and that is correct - importing
contaminated content to turn it green would be the wrong repair. Filed to the
site agent's inbox with the three lines and suggested wording; every one of them
makes its point without the client in it, which is a good sign the rule costs
nothing.
