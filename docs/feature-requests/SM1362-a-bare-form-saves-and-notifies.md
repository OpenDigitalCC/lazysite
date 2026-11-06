---
id: SM1362
title: "SM1362: a bare form saves to file storage and notifies the owner"
subtitle: "A form with no handler named should work: its submissions are kept in the site's file storage and the site's owner is told. Binding a handler becomes the exception."
brand: plain
standard-margins: true
status: candidate
raised: 2026-11-06
raised-by: "release manager (SM1350 discussion: 'the default save to file storage is a sensible form default')"
area: forms
status-note: "Filed 2026-11-06 under SM1350. Waiting on the sites agent's evidence of what forms have really needed (lazysite-sites inbox request, 2026-11-06)."
---

# Proposed

- **Default storage:** a form with no handler keeps each submission in the site's file storage.
- **Default notice:** the site's owner (or the address the site names) receives a notice through the site's notification sender. The notice links to the submission; it does not contain it.
- **Spam:** protection is on by default (the existing checks), with a per-site send-rate limit on notices.
- **Custom handlers:** a sysop still approves a custom handler. The default needs no approval.
- **Ready-made forms:** contact, enquiry and sign-up, each creatable in one step (manager, wizard or `create_form`).

# Waiting on

- The sites agent's answers: which forms needed more than this, and which setup steps could have been avoided.
- What "file storage" means today for an unbound form, checked against the code before building.
