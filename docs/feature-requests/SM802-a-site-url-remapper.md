---
id: SM802
title: "SM802: a site URL remapper - prefix redirects, with a count and a last-used date"
subtitle: "From a live migration: two sites are replacing Odoo websites on their existing hostnames, and mail already in the world - notifications, invoices, helpdesk tickets - carries links to paths the new site does not serve. The engine has no outward redirect at all. The request is well-specified and its second half, the count and last-used per rule, is the part that would normally be left out."
brand: plain
standard-margins: true
status: candidate
---

# What is missing, verified

There is no outward redirect in the engine, and the reporter checked each
candidate before saying so:

- `aliases` and `aliases_temp` issue real 301/302 but only **inward** - the
  redirect always targets the page carrying it. Confirmed: `canonical_url_for`
  builds the target from the page's own path (see [[SM801]], which was the
  other half of this reporter's day).
- `.url` files are **not** redirects - they fetch a remote body and render it
  here. One document said otherwise and that error is corrected as [[SM803]].
- `raw:` and `api:` set content type and caching; neither can set a status or a
  `Location`.
- No site- or domain-level redirect key exists in the configuration.

# The shape asked for

Ordered rules in configuration, each mapping a path prefix to a destination:

    /web       -> https://backend.example.com   302   keep path, query
    /helpdesk  -> https://backend.example.com   302

The requirements the reporter derives from the case rather than from taste, all
of which are worth keeping:

- **Preserve path and query.** A helpdesk link landing on a dashboard has not
  been redirected in any useful sense.
- **Prefix matching on a segment boundary.** `/web` matches `/web` and
  `/web/login` and must not match `/website-terms`. A naive `startsWith` gets
  this wrong.
- **A real page always wins**, the same precedence aliases have, so a remapper
  cannot shadow site content.
- **302 by default, 301 selectable.** A migration's destination can move, and a
  cached permanent redirect to a host that later moves is a trap.
- **Static destinations only.** The destination comes from configuration and
  never from the request - a `?to=` convenience would make every lazysite an
  open redirect. The reporter asks for that written into the design note so it
  is not added later as an obvious kindness, and they are right to.

# The half that is easy to leave out

A **hit count and a last-used date per rule**, and the second is the load-bearing
one. A migration redirect exists to cover links already in the world; when the
last of those has been followed, the rule can go. Without a last-used date the
only safe answer is to keep every rule forever, which is how redirect tables
become archaeology. The count separately answers whether the *source* has been
fixed - a rule whose count keeps climbing says something is still minting the
old links.

That reasoning is the strongest part of the request and should survive into
whatever is built.

# The decisions this needs before it is built

Not started, and these belong to the release manager:

- **Where do the rules live?** `lazysite.conf`, a reserved-tree file of their
  own, or per-domain? Per-domain is what the case actually needs - the two
  sites have different backends - and that makes it a domain-configuration
  feature rather than a site one.
- **Who may write them?** A rule sends visitors to a third-party host, which is
  the same class of authority as a connector's destination (SM579's answer:
  the operator writes it, an author references it). If an author may add a
  prefix rule, the open-redirect argument above stops being about `?to=` and
  starts being about who can write configuration.
- **Where do the counts live, and what writes them?** A counter on a request
  path is a write on every redirect. The visitor log already records requests;
  the reporter asks for full detail there as well as the aggregate, which
  suggests the log is the source and the count is derived rather than a second
  store to keep in step.
- **Is this a plugin or core?** The title says plugin. The boundary the release
  manager set for SM579 applies: one bounded act, and every generalisation
  refused by default.

# The workaround, which is worth shipping either way

The reporter has a site-level answer working today: `404.md` reads a JSON
config through `tt_page_var`, publishes it as `data-` attributes, and a small
script matches the prefix and does `location.replace(...)`. Verified on a live
site with parameters intact, and correctly declining `/website-terms` and
ordinary mistyped paths.

Its three faults are exactly what the feature fixes, and the reporter names
them: the status is **404, not 302**; it needs JavaScript, so a visible
fallback link must be carried; and there is nowhere to record a count or a
last-used date. They offer it as a documented pattern if the feature is not
soon, and that seems right - a migration where the URL scheme changes and the
parameters must survive is not unusual.

# Provenance

`inbox/2026-09-09-site-url-remapper-plugin.md`. NOT BUILT: this is a feature
with a configuration surface, an authority question and a counting question,
and it is the release manager's to schedule.

# Ruled 2026-09-09 by the release manager

All three of the open shape questions, as recommended:

- **Where the rules live, and who writes them: per-domain, operator-only.**
  Per-domain because that is what the case needs - the two sites have different
  backends - which makes this domain configuration rather than site
  configuration. Operator-only because a rule sends a visitor to a third-party
  host, and that is the same class of authority as a connector's destination,
  which [[SM579]] already settled: the operator writes it, an author references
  it. The open-redirect argument therefore stays about `?to=` and does not
  become an argument about who may write configuration.
- **Counts: derived from the visitor log.** The log already records the
  requests, and the reporter wants the detail there as well as the aggregate.
  One source, the count derived - no second store to keep in step, and no write
  added to the request path on every redirect.
- **Shape: a plugin, one bounded act.** The boundary set for SM579 applies, and
  every generalisation is refused by default.

Still not started. These were the decisions it needed first.
