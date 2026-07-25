---
title: "SM211 - [WITHDRAWN] WebDAV lazysite/ write-guard (was: incomplete deny-list)"
subtitle: "Filed as a security gap after a DAV PUT to lazysite/nav.conf succeeded; on reading the actual guard (authorise/authorise_layout, not the coarse blocked_paths list) it is correct - lazysite/ is denied except deliberate, capability-gated carve-outs. No fix; nav.conf write is by design. Kept for the record."
brand: plain
status: parked
status-note: "WITHDRAWN 2026-07-25. The original finding was a MISREAD: I inspected the content-namespace `blocked_paths` list, not the actual lazysite/ guard. The real guard (lazysite-dav.pl `authorise` ~1098 -> `authorise_layout` ~1150) denies ALL of lazysite/ EXCEPT deliberate carve-outs. nav.conf clobbered during the check-over because the account legitimately holds manage_nav - an authorised write of malformed content, not an access-control hole. No engine fix ships. See below."
---

# SM211 - [WITHDRAWN] WebDAV lazysite/ write-guard

## What I originally claimed (wrong)

During the 0.9.14 API/DAV check-over, `PUT /dav/lazysite/nav.conf` returned 204 and
overwrote the live nav. I filed this as a security gap - that the DAV block-list was
allow-by-omission and left `lazysite/lazysite.conf`, `nav.conf`, `templates/`,
`logs/` writable. That conclusion was based on the wrong code: the content-namespace
`blocked_paths` list (`lazysite-dav.pl` ~1428), which is NOT the guard for `lazysite/`.

## What the guard actually does (correct)

`lazysite-dav.pl` `authorise` routes EVERY `lazysite/` path through `authorise_layout`
(~1098), and `authorise_layout` (~1150) is explicit:

> *"Only the layouts subtree is reachable; the rest of lazysite/ is denied."*

So the tree is properly protected, with three DELIBERATE, capability-gated carve-outs
(each cross-plane-consistent with the control-API / MCP that edit the same file):

- `lazysite/nav.conf` - editable, gated by `manage_nav` (same cap as `nav-save` /
  `set_nav`). Benign structure, no privilege keys (~1071).
- `lazysite/forms/<name>.conf` (non-secret) - editable, gated by `manage_forms`;
  `smtp.conf` / `handlers.conf` stay denied (~1086).
- `lazysite/layouts/**` - theme/layout authoring, gated by `manage_themes` /
  `manage_layouts`, with the active layout/theme read-only and an executable/config
  extension block (~1142).

Everything else under `lazysite/` - `lazysite.conf`, `templates/`, `logs/`, `auth/`,
`cache/`, `manager/`, `.install-state.json` - returns **403**. I verified this against
`authorise_layout`, not just by testing.

## So the incident was...

An AUTHORISED write. `claude-code` holds `manage_nav`, so `PUT /dav/lazysite/nav.conf`
is exactly as permitted as `nav-save`. The nav broke only because the test PUT wrote
malformed content (`x`) - the same way a malformed `.md` PUT renders badly. Raw
WebDAV is a byte transport; it does not structure-validate a file the way the
manager/API `nav-save` (structured JSON) does. That is a property of DAV, not a hole.

## Residual (minor, likely won't-fix)

The only real observation is that a raw DAV `PUT` of a malformed `nav.conf` (or any
structured `lazysite/*.conf` carve-out) is not content-validated, so it can silently
produce a broken nav until re-saved. This is consistent with DAV's raw nature and low
value to fix; the structured surfaces (manager, control API, MCP) validate. If ever
wanted, a lightweight parse-check on the DAV write path for the `.conf` carve-outs
(reject clearly-malformed content, 422) would close it - but it is not a security
issue and not scheduled.

## Lesson

Read the ACTUAL enforcement path before filing a security finding - the coarse
`blocked_paths` list looked like the guard but was a different mechanism.
