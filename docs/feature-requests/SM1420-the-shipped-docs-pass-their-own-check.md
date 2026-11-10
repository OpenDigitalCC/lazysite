---
id: SM1420
title: "SM1420: the shipped docs pass their own lazysite check"
subtitle: "On a site that serves the shipped docs under /docs/, lazysite check flagged four titles each shared by two shipped pages and two shipped pages with no description. Each page now has a title that says what it is, the two have a description, and a test runs the check over the whole shipped tree."
brand: plain
standard-margins: true
status: shipped
raised: 2026-11-10
raised-by: the 0.16.9 deploy to edge, which ran lazysite check (release manager)
area: docs, check
status-note: "SHIPPED (PENDING): eight shipped docs pages retitled so no two share a title, and site-migration and update-channel given a description; no page merged, moved or deleted. t/tools/552 runs lazysite check itself over the shipped docs tree, so either rule breaking again fails the suite."
---

# What was observed

The 0.16.9 deploy to edge ran `lazysite check` on a site serving the shipped docs under
/docs/. It warned that four titles were each shared by two pages, and that two pages had
no description (SM1357's rules).

# What changed

Each pair is a full guide at the top of the docs tree and a short summary under
features/. Neither is a duplicate, so none was merged, moved or deleted; the paths and
their content history stay.

| Page | New title |
|---|---|
| auth.md | Authentication: the full guide |
| features/configuration/auth.md | Authentication: protecting a page |
| forms.md | Forms: the full guide |
| features/authoring/forms.md | Forms: the form block in brief |
| manager.md | Manager: the full guide |
| features/configuration/manager.md | Manager: enabling and configuring |
| payment.md | Payment: the full guide |
| features/configuration/payment.md | Payment: protecting a page |

features/configuration/site-migration.md and features/configuration/update-channel.md
gained a `subtitle:`, which is what the check reads as the description.

# How it is held

t/tools/552 lays the whole shipped docs tree under /docs/ of a scratch site and runs
`lazysite-check.pl` over it. It restates no rule: the shared-title and missing-description
findings are the check's own. On the 0.16.9 tree it fails with the six findings above.
