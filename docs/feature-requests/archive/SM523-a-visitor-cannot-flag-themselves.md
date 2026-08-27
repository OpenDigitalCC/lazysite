---
title: "SM523: a visitor cannot flag themselves"
subtitle: "A submitter who posts the engine's own quarantine keys mutes their notification and skews the blocked and quarantined counts."
brand: plain
standard-margins: true
status: shipped
status-note: "SHIPPED 0.10.32 (EDGE): parse_post keeps only the five protocol keys the renderer emits (_form _page _hp _ts _tk) and drops every other client-supplied underscore key before any gate reads the submission, so _quarantined / _spam_reason (and _ip, _submitted, _id) are set by the engine alone; proving test t/unit/forms/11-a-visitor-cannot-flag-themselves.t posts a self-flagged submission through the real handler and asserts the record carries neither key, the bell rang for both posts and form-events holds two stored outcomes. FOUND 2026-08-25 by the plugins structural review, PROVEN by probe tmp/plugins-probe-forms-client-quarantine.pl; class: security-integrity; recommended timing: BEFORE-BETA-PUBLISH. PLANNED under SM516 for 0.10.33 unless the operator pulls it forward. A visitor posting _quarantined=1&_spam_reason=visitor-chosen gets a stored record carrying both keys, the bell is silent (one notice for two posts) and form-events logs quarantined: parse_post keeps every client-supplied underscore key and the flag block at 202-206 only ever sets the flags, never clears or owns them. The fix strips client underscore keys before the engine sets its own."
---

# The finding

A visitor posting `_quarantined=1&_spam_reason=visitor-chosen` to a form
gets a record carrying both keys, the notification bell is silent (one
notice for two posts) and `form-events` logs `quarantined`. `parse_post`
in `plugins/form-handler.pl` keeps every client `_` key, and the flag
block at `plugins/form-handler.pl 202-206` only ever sets the flags on
top of what arrived, so a client value survives untouched. A sender can
therefore mute their own notification and skew the blocked and
quarantined statistics.

# Why it matters

Security-integrity: a client controls engine-owned flags on the stored
record. The quarantine markers exist so the operator can trust what the
engine decided; here the visitor decides for it.

# The proving test

NEW `t/unit/forms/11-a-visitor-cannot-flag-themselves.t` with
`ok(!exists $row->{_quarantined})` and `is($notices, 1)`.

# Fix shape

Strip client-supplied `_` keys in `parse_post` (or immediately after it)
so that only the engine's own block at 202-206 can set `_quarantined`
and `_spam_reason`.
