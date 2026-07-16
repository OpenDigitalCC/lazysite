---
title: "SM156 - Domain configuration check + panel polish"
subtitle: "Verify a domain resolves, points here, has TLS and terminates on this instance; plus live-testing fixes"
brand: plain
status: shipped
status-note: "delivered 2026-07-16 in 0.7.19; refines the SM154/SM155 domains admin from live-testing feedback"
---

# SM156 - Domain configuration check

Live-testing the domains panel raised a recurring question an operator cannot
answer from inside lazysite alone: *is this domain actually wired up?* SM156 adds
a hybrid check and folds in the panel fixes and preview/alias bugs found in the
same session.

## The domain check

For a registered domain, four ordered checks answer "is it configured to serve
THIS install, live?":

DNS resolves
: the host name resolves to one or more addresses.

Points to this server
: one of those addresses is this server's own (the address Apache accepted the
  manager request on, `SERVER_ADDR`).

HTTPS certificate valid
: a TLS connection to the host:443 completes with a trusted certificate that
  matches the host (SNI + peer verification); the certificate CN and expiry are
  reported.

Serves this lazysite
: an HTTPS request to the host lands back on this instance - confirmed by a new
  public marker, `/.well-known/lazysite-instance.json`, which echoes a stable,
  non-sensitive per-install id (one-way over the docroot path). A different id,
  or no marker, means a different server answered.

## Why hybrid (not pure client-side)

A browser cannot do a DNS lookup, read a server's IP, or inspect a certificate -
a cross-origin `fetch` only reports "loaded or not". So the authoritative checks
run **server-side** (`domain_check` in `Lazysite::Manager::Domains`); the panel
then adds a **browser-side probe** (fetch the marker over the candidate host and
compare it to the manager's own) for the visitor's-eye view.

## Surfaces

- Control-API action `domain-check` (manage_config, GET, registered-host only -
  the outbound probe is bounded, no SSRF to arbitrary targets).
- CLI `lazysite-domains check <host> [--self-ip IP]`; exit 2 when not yet ready,
  so an external orchestrator can gate on it.
- The Domains panel gains a **Check** button per domain, a results overlay, and
  a browser probe.

Fixing the SSRF bound also tightened `domain-preview`, whose registered-host
guard had been a no-op (it matched the ever-present default row).

## Also in this increment (live-testing feedback)

- Preview: fixed an auth error on wrapped (Apache/Hestia + dev-server)
  deployments where `LAZYSITE_PROCESSOR` points back at the manager-api; added an
  "Open live site" new-tab link beside the in-session render.
- Alias: now mirrors its canonical's full presentation (title/theme/layout/nav/
  search), not just content root + site URL.
- Content folder: optional (a domain with none serves the default site);
  reserved-path enforcement centralised in `Common::path_is_reserved`.
- A `domain` template variable (the host being served) for per-domain content.
- Panel usability: full-width table-styled add form, auto-derived site address,
  friendly labels, an overflow-safe table, and a pre-filled styled edit row.
- Hestia `update-all` discovers by the web template (`--template-only`), not the
  marker union.

## Out of scope

- lazysite never configures DNS, the web-server domain alias or TLS - those are
  the operator's / Hestia's / an orchestrator's job. SM156 only *checks* them.
