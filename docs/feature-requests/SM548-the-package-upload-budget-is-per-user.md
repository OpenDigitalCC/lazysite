---
title: "SM548: the package upload budget is per user"
subtitle: "The site-package upload calls the rate check with the docroot where a username and length belong, so every user of an instance shares one budget and the byte limit is inert."
brand: plain
standard-margins: true
status: shipped
status-note: "SHIPPED 0.10.32 (EDGE): action_site_backup_upload now calls check_upload_rate($auth_user, length $raw), matching the file-upload call site, so the budget is keyed on the user and the byte limit fires. t/unit/manager/109 drives the action under the load-only API with a 1 MB hourly budget and asserts a larger package is refused as kind rate with no undefined-length warning and nothing stored, and pins the call's arguments at the source (the load-only path returns before $auth_user is set). FOUND 2026-08-25 by the backups structural review, PROVEN by probe tmp/bp-probe-rate-key.t; class: operability; recommended timing: 0.10.33. PLANNED under SM516 for 0.10.33 unless the operator pulls it forward. action_site_backup_upload (lazysite-manager-api.pl 2433) calls check_upload_rate($DOCROOT) where the signature (Upload.pm 63-64) is ($username, $content_length); the file upload at 443 passes ($auth_user, $len) correctly. The probe shows the rate DB key becomes /tmp/<docroot>:<hour>:bytes and the byte comparison warns on an undefined length. Every user of an instance shares one package-upload budget, and the byte limit never fires. Outside the five reviewed files, but it is Upload's API being misused."
---

# The finding

`action_site_backup_upload` (`lazysite-manager-api.pl 2433`) calls
`check_upload_rate($DOCROOT)` where the signature (`Manager/Upload.pm
63-64`) is `($username, $content_length)`. The ordinary file upload at
`lazysite-manager-api.pl 443` passes `($auth_user, $len)` as intended.

The probe shows the rate DB key becomes `/tmp/<docroot>:<hour>:bytes`,
and the byte comparison warns on an undefined length. Every user of an
instance therefore shares one package-upload budget, and the byte limit
is inert.

# Why it matters

Operability: one user's package uploads exhaust the budget for every
other user on the instance, and the size cap that should bound a single
upload never applies.

# The proving test

`bp-probe-rate-key.t` as a test: key carries the user, byte limit fires.

# Fix shape

Pass `($auth_user, $len)` at the site-package upload call, matching the
file-upload call site.
