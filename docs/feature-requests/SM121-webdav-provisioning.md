---
title: "SM121 - WebDAV provisioning: wire /dav/ on enable + health check"
subtitle: "Turning on webdav_enabled should make /dav/ actually route"
brand: plain
---

::: widebox
After `webdav_enabled` was turned on, `/dav/` still returned an nginx **404 for
everything - even unauthenticated** (404, not a 401 challenge): the nginx location was
not wired. Same symptom on a previous instance. Enabling WebDAV should be one operation
that also wires the web-server `/dav/` location, and an unauthenticated `GET /dav/`
should return **401, not 404** - the fastest way to tell "route missing" from
"auth/scope problem". Rated **High**.

## Shape

- Treat "enable WebDAV" as wiring the `/dav/` location in the web-server config (the
  Hestia/nginx template), not just flipping `webdav_enabled` in lazysite.conf.
- Add a health check: unauthenticated `GET /dav/` returns 401 (route present, auth
  required), never 404. The doctor (lazysite-check) could probe this.
- 404-vs-401 is the diagnostic: 404 = route missing (provisioning), 401 = auth/scope.

## Status

**Partially SHIPPED in v0.4.41**: the doctor gains `--check-dav URL` (the 401-vs-404 health check) and the runbook documents the route requirement. Auto-wiring the proxy is environment-specific (the Apache template already wires /dav; a 404 is the nginx/proxy layer, now diagnosable).

Queued. Spans the Hestia/web-server template + a doctor probe. High value - recurring.
