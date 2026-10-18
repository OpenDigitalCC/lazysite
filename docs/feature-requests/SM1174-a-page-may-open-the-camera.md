---
id: SM1174
title: "SM1174: a page may open the camera"
subtitle: "Front matter `camera: self` makes that page alone send camera=(self) on https; every other page keeps camera=()."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-18
raised-by: lazysite-sites agent, inbox/2026-10-17-oom-lab-stock-and-picking-apps-findings.md row L-16
area: security
status-note: "SHIPPED on n663 (claude/n663-a-page-may-open-the-camera): lib/Lazysite/SecurityHeaders.pm and its processor copy; t/unit/processor/143, t/unit/mcp/33, t/lint/55."
---

# What happened

Row L-16 of the OOM Lab stock and picking findings (2026-10-17):

> **Phone camera.** Every page sends `Permissions-Policy: camera=()` from a
> fixed list (`Lazysite::SecurityHeaders`), so no page can open a live camera
> viewfinder even on https. The lab scans by photo (a capture file field, which
> the policy does not block, decoded on the phone) and that works; a live
> viewfinder - what warehouse staff expect - needs a site- or page-level
> allowance for `camera` (proposed 2026-09-27 as P1 for the Expo card capture).
> Together with a web-app manifest and service worker (the pocket portal
> review's L1), this is what makes a lazysite page a usable warehouse PWA.

The 2026-09-27 proposal is recorded in [[SM710]] ("A shape for the opt-in, and a
second driver"): the Expo business-card capture, with the hand-off half in
[[SM905]]. It proposed two keys (an instance ceiling `permissions_policy_allow`
and a page key `device: camera`) and said "if only one half is built, build the
page half".

The ruling (release manager, 2026-10-18):

> "Per page, opt-in: a page's front matter may say `camera: self`; that page
> alone sends camera=(self) on https. Every other page keeps camera=().
> Shown in the manager's page status."

# What shipped

- Front matter `camera: self` on a page. That page, over https (the request
  `$ENV{HTTPS}` already marks secure, the same test that gates HSTS and the
  cookie's Secure flag), sends `camera=(self)`; every other directive of the
  policy is unchanged. Over plain http the key is ignored and the page keeps
  `camera=()`.
- `self` is the only value that grants. `none` and an absent key keep
  `camera=()`; any other value (`*`, a URL, `Self`, empty, given twice) also
  leaves the page on `camera=()` and is reported by the validator
  (`kind: camera-unreadable`, in `validate_page` and `lazysite validate`, via
  `Lazysite::Validate::validate_content`). The engine's reader takes the key
  from the front matter only, so a body line reading `camera: self` grants
  nothing.
- The policy is decided per response from the page's own source (the peek the
  engine already uses for `ttl` and `nocache`), on the fresh-render, cache-hit
  and ttl-hit paths. The cache stores HTML, never headers, so a cached page keeps
  its own policy and a page without the key is never served another's.
- Who may set it: whoever may write the page's front matter today. Pages are
  files; the control API, the file editor and the MCP write tools all write the
  same front matter, and the one validator reads it. No new permission.
- `page_status` (MCP; the manager's page status) reports `camera: "self"` and a
  `camera_note` ("camera allowed on this page ... https only; over plain http the
  page keeps camera=()") for such a page.
- Docs: one entry in starter/docs/frontmatter.md, one clause in
  starter/docs/ai-connector-tools.md.

Scope: camera only. No microphone, geolocation or other directive is relaxed,
and there is no instance-wide key; [[SM710]] (a general allowance, the
microphone) stays open as its own decision.

Tests: t/unit/processor/143 (https page sends camera=(self) with the rest of
the policy unchanged; same page over http, a page without the key, a body line,
`none` and `*` all send camera=(); cached and ttl hits keep each page's own
header), t/unit/mcp/33 (validator names `*`, a URL, `Self`, empty; page_status
shows the page), t/lint/55 (module and processor copy agree on every
https/camera pair).
