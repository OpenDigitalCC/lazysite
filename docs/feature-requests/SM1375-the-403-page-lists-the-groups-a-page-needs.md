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
status-note: "SHIPPED (PENDING) on n759: templates/system/403.md writes the groups as <ul class=auth-required-groups>, on a front-matter gate and an ACL read-list refusal; a site's own 403.md is unchanged. Ruling 141: the names are HTML-escaped in the stash. Register entries confirmed (rulings 141, 142). t/integration/350, 356."
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
`auth_required_groups`, which entered the stash raw. A read list naming a group with
markup rendered that markup on the 403 page. A front-matter gate's names are
shape-checked (`Lazysite::Validate`), and one with markup makes the rule unreadable. This predates SM1375 (the same value
reached the page unescaped after Markdown had run) and is written only by accounts
that can already put markup in a page.

# Ruling 141: the names are escaped

Release manager, 2026-11-06: fixed in 0.16.6. `auth_required_groups` is
HTML-escaped where `lazysite-processor/render.pm` builds the stash, with the same
`_esc_html` the other auth values get; `%AUTH_CONTEXT` stays raw for access control.
t/integration/356 renders a read list naming `@<i>bad</i>` for a refused visitor and
finds it escaped, and fails with the escape removed; it also holds that a
front-matter gate naming markup is refused naming no group. docs/SECURITY.md, the
2026-11-06 entry for ruling 141: a hardening, not a vulnerability fix, no ADR 0007
trigger, confirmed.
