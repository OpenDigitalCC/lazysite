---
id: SM1375
title: "SM1375: the 403 page lists the groups a page needs"
subtitle: "The shipped 403.md named the required groups as '- reviewers' lines run into one paragraph. Markdown reads the page before Template Toolkit fills it, so the list never started. The template writes the list as HTML."
brand: plain
standard-margins: true
status: shipped
raised: 2026-11-06
raised-by: "release manager (triage T-56)"
area: access
status-note: "SHIPPED (PENDING) on n759: templates/system/403.md writes the groups as <ul class=auth-required-groups>, on a front-matter gate and an ACL read-list refusal; a site's own 403.md is unchanged. The 0.16.6 walk (SM1380) found the names unescaped by the stash: register entry drafted. t/integration/350."
---

# What happened

The shipped `templates/system/403.md` wrote the groups a page needs as a Markdown
list inside a `FOREACH`. Markdown reads the page before Template Toolkit fills it,
and the directive line sat against the `- [% g %]` item, so the list never started:
a refused visitor saw "- reviewers - leads" inside one paragraph, on a front-matter
group gate and on an `auth/acls.json` read-list refusal (SM1365) alike.

# What shipped

The template writes the list as HTML, `<ul class="auth-required-groups">` with one
`<li>` per group, so the groups render as a list. A site with its own `403.md` is
unchanged.

# Tests

t/integration/350 renders both refusals and finds a `<ul>` with an `<li>` per group,
and no "- name" line; it fails with the template reverted.

# Found at the 0.16.6 compliance walk

The change's commit says the stash already escapes the `auth_*` values (SM709). It
escapes `auth_user`, `auth_name`, `auth_email` and each of `auth_groups`, but not
`auth_required_groups`, which enters the stash raw. A read list naming a group with
markup renders that markup on the 403 page. This predates SM1375 (the same value
reached the page unescaped after Markdown had run) and is written only by accounts
that can already put markup in a page. docs/SECURITY.md, the 2026-11-06 SM1375,
SM1378 entry, records it as residual risk for the release manager's confirmation,
with the one-line fix (escape it in `lazysite-processor/render.pm`) left for a
ruling.
