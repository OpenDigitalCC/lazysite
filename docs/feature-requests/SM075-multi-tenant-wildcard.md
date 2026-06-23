---
title: "SM075 - Wildcard multi-tenant hosting"
subtitle: "Many cheap, ephemeral lazysite sites under one wildcard vhost, auto-provisioned via CLI and API"
brand: plain
---

::: widebox
Point a wildcard DNS record (`*.explore.lazysite.io`) at one host, give it a
single Apache vhost with a wildcard certificate, and serve **many sites from one
shared lazysite install**. Each subdomain is a tenant: its own content and
`lazysite/` state under `/srv/lazysite-tenants/<host>/public_html`, selected
per-request by `VirtualDocumentRoot`. New sites are created on demand by a CLI
and an API - no per-site Hestia domain, no per-site install. A test site that
proves out is later promoted to its own permanent domain.
:::

## 1. Goal and motivation

Spinning up a throwaway site today means a full Hestia domain plus a lazysite
install - too heavy for short-lived experiments. The goal: **cheaply run many
domains**, auto-provisioned when required, with a clean path to graduate a
keeper to its own permanent domain. The trust boundary is explicitly the Unix
web user: all tenants on a wildcard share one OS account and one copy of the
lazysite code. That is acceptable - these are operator-controlled test sites,
not mutually-hostile tenants.

## 2. Web server: Apache (decision)

lazysite is an Apache-CGI application - `FallbackResource`, `ScriptAlias`, the
`RequestHeader unset X-Remote-*` trust-stripping, `<FilesMatch>`, `+ExecCGI`,
and direct reads of `DOCUMENT_ROOT` / `REDIRECT_DOCUMENT_ROOT`. Apache's
`mod_vhost_alias` provides mass virtual hosting natively and sets the per-Host
docroot lazysite already consumes, so this feature is near-zero application
code. nginx has no native CGI (it would need `fcgiwrap` and a re-expression of
the PATH_INFO/DOCUMENT_ROOT contract and every Apache-ism above) for no win at
this scale; Hestia's application vhost is Apache regardless. **Decision: Apache.**

## 3. Architecture

```datatable
columns: Piece | How
widths: 4.5cm | X
bold: 1
tone: medium
---
DNS | a wildcard `*.explore.lazysite.io` A/AAAA record at the host.
Vhost | ONE Apache vhost for the wildcard, with `ServerAlias *.explore.lazysite.io` and a **wildcard TLS cert** (Let's Encrypt DNS-01).
Per-tenant docroot | `VirtualDocumentRoot /srv/lazysite-tenants/%0/public_html` - Apache sets `DOCUMENT_ROOT` per request from the Host, so each subdomain resolves to its own tree automatically.
Shared code | ONE `ScriptAlias /cgi-bin/` to a single lazysite `cgi-bin`. The scripts read the per-request `DOCUMENT_ROOT`, so one copy of the code serves every tenant.
A tenant | `/srv/lazysite-tenants/<host>/public_html/` with its own `lazysite/` state - users, auth secret, ACLs, themes, config. Fully isolated content + auth; shared binaries + OS user.
```

The leverage: lazysite **already** keys everything off `DOCUMENT_ROOT`
(`REDIRECT_DOCUMENT_ROOT` as fallback), so the processor, dav, auth and
manager-api work per-tenant with no routing code of their own.

## 4. Provisioning: CLI and API

Tenants are created on demand, so provisioning is automatable from both a
command line and over HTTP (for an external system to spin sites up):

```datatable
columns: Operation | CLI | API
widths: 3.5cm | X | X
bold: 1
tone: medium
---
Create | `lazysite tenant new <sub>` | `POST /provision?action=tenant-new` `{ sub }`
List | `lazysite tenant list` | `GET  /provision?action=tenant-list`
Remove | `lazysite tenant remove <sub>` | `POST /provision?action=tenant-remove`
Promote | `lazysite tenant promote <sub> <domain>` | (CLI / operator only)
```

Create lays down the tenant docroot, seeds starter content, and writes a fresh
per-tenant `lazysite/` (new auth secret, empty users/ACLs, default config). This
is `install.pl` in a **content-only mode**: it seeds the docroot and per-tenant
state but does NOT copy code - the `cgi-bin` is the shared install. Promote
creates a real Hestia domain, moves the (portable) tenant tree there, and runs a
full code+content deploy; the test subdomain is then freed.

The **provisioning API is a host-level, cross-tenant surface** - it creates and
destroys sites - so it is NOT part of any tenant's manager-api. It is a separate
endpoint with its own strong auth (a dedicated provisioning credential / operator
token), rate-limited, and ideally bound to localhost or an allowlist where the
automation runs. This is the most security-sensitive new surface in the feature.

## 5. De-risk before building

The one unknown is whether `DOCUMENT_ROOT` propagates to the **directly
ScriptAlias'd** CGIs (`/dav`, manager-api, auth) under `VirtualDocumentRoot`.
The processor is fine (it runs via `FallbackResource`, and lazysite already
reads `REDIRECT_DOCUMENT_ROOT`). Confirm the aliased scripts see the per-tenant
root first; if they do not, the fallback is a tiny shim that derives the tenant
docroot from `SERVER_NAME` inside the shared scripts (one helper + one env
override). Either way the change is small - but verify before committing to the
zero-code path.

## 6. Security and operational notes

- **Host validation**: only `[a-z0-9-]+\.explore\.lazysite\.io` resolves to a
  tenant path; reject anything else so a crafted Host cannot map `VirtualDocumentRoot`
  to an unexpected directory.
- **Shared trust boundary**: all tenants run as one OS user and share the code.
  Isolation is of content and auth, not a sandbox between hostile tenants -
  stated and accepted (operator-controlled test sites).
- **Provisioning auth**: the create/remove API must be strongly authenticated
  and tightly scoped; it is effectively root-of-sites.
- **Wildcard TLS**: one DNS-01 wildcard cert covers every subdomain.
- **Resource hygiene**: ephemeral sites accumulate - a TTL / sweep for stale
  tenants is worth considering (e.g. auto-remove untouched test sites after N
  days).

## 7. Open questions

- Subdomain naming/validation rule (proposed `[a-z0-9-]+`, lowercased).
- A cross-tenant **super-admin** view (list/create/kill sites from one UI), or is
  CLI + API enough to start? (Leaning: CLI + API first; UI later.)
- Who may create a tenant - operator-only, or a delegated provisioning token for
  the automation that needs it.
- TTL/auto-sweep policy for abandoned test sites.

## 8. Build sequence (proposed)

```datatable
columns: Step | Scope
widths: 3cm | X
bold: 1
tone: medium
---
0 | Verify `DOCUMENT_ROOT` propagation under `VirtualDocumentRoot` for the ScriptAlias'd CGIs (§5).
1 | The wildcard Apache vhost template (mod_vhost_alias + shared cgi-bin + wildcard cert) - sibling to lazysite.tpl.
2 | `install.pl` content-only mode (seed a docroot + per-tenant lazysite/ state without copying code).
3 | The tenant CLI: new / list / remove / promote.
4 | The provisioning API (host-level, strongly authed) mirroring the CLI for auto-provisioning.
5 | Promote-to-permanent-domain flow; optional TTL sweep.
6 | Tests + docs.
```
