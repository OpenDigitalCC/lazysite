# SM140 - First-party analytics: lazysite records its own traffic

Status: agreed 2026-07-10 (design accepted; two-tier model confirmed - first-party
log owns the owner/visitor record, server logs are the operator diagnostic.
Per-request append I/O accepted as inherent to CGI until a persistent
runtime exists - see Open questions.)
Driver: the 0.6.7 field round. Getting visitor stats working on a Hestia host
took server-owner ACL grants on /var/log/apache2/domains plus (for full
fidelity) a vhost `LAZYSITE_ACCESS_LOG` override - and the Apache log still
undercounts because nginx fronts it. Analytics must not require touching the
web server, and must not miss page views.

## Problem

The stats plugin parses the WEB SERVER's access log. Three structural faults:

1. **Permission dependency.** Panel hosts own their logs as root; www-data
   cannot read them until the server owner intervenes (ACLs that must also
   survive logrotate). "Out of the box" is impossible by design.
2. **Topology dependency.** With nginx in front of Apache, the Apache log
   misses everything nginx serves directly; picking the right log needs a
   vhost env override - more server-owner work, different on every stack.
3. **Format/rotation dependency.** Combined-format assumptions, rotated-away
   history, and per-distro paths make auto-detection a heuristic that can
   quietly pick the wrong (or an incomplete) file.

## Design: the processor logs its own requests

Production routing is `FallbackResource /cgi-bin/lazysite-processor.pl`: the
processor already handles EVERY request that is not a literal file on disk -
all page views (including page-cache hits, which it serves itself), all
clean-URL 404s, and all scanner probes. It can therefore record its own
traffic in the tree it owns, with the same code path on Apache, nginx+Apache,
and the dev server.

lazysite/logs/access-YYYYMMDD.jsonl
: One compact JSON line per request, written by the CGI (so ownership and
  writability are correct by construction - no ACL, no vhost change, ever).
  Fields: ts, path, status, referrer (external only), ua_class
  (human/bot/agent, classified at write time with the existing stats
  heuristics), ua (truncated), ip (ANONYMISED AT WRITE by default - a real
  privacy improvement over retaining raw server logs), channel
  (page/404/form/api/dav), cache (hit/miss). All attacker-controlled fields
  sanitised (control chars stripped, length-capped) against log injection.

Write mechanics
: open O_APPEND + single write + close, per request. Lines are far below
  PIPE_BUF, so concurrent CGI appends cannot interleave; no locking. Cost is
  one syscall trio on top of a CGI process start - negligible (bench-gated).

No write buffering (decided 2026-07-10)
: under plain CGI every request is its own process, so there is nothing to
  buffer ACROSS - a buffer would live and die inside one request, saving
  nothing. Cross-request batching would need a daemon or shared state, and
  loses the buffered tail exactly when it matters most (the requests just
  before a crash). One append per request IS the minimum I/O. Revisit only
  if a persistent runtime (FCGI) ever lands.

500s are recorded too
: the recorder writes from a die-guard as well as the normal output paths, so
  a runtime failure in the processor still leaves a status-500 line. (A
  compile-level or exec-level crash cannot self-log - see the two-tier note.)

Rotation and retention
: daily files; on the first request of a new day, unlink files older than
  `retention_days` (default 90). Self-managing size; no logrotate dependency.

stats.pl reads first-party data first
: the scan aggregates access-*.jsonl when present, with the SAME output shape
  the stats page already renders. The server-log parser remains as an
  OPTIONAL enrichment/fallback (`source: server-log`) for asset-level detail
  and pre-SM140 history - useful when readable, never required. The
  needs_config error state disappears for the default path.

## Two tiers: analytics (first-party) vs diagnostics (web server)

The web-server log's ROLE changes from load-bearing to diagnostic; the access
problem on panel hosts is not solved by SM140 - it is re-scoped to the layer
where root access already exists.

Tier 1 - first-party analytics (this spec, zero setup)
: everything FallbackResource routes to the processor: every page view (cache
  hit or miss), every clean-URL 404 and scanner probe, AND every MISSING
  asset - a missing image is a non-existent file, so the web server hands it
  to the processor, which 404s it and records it. Runtime 500s are recorded
  by the die-guard. This is the complete visitor-experience record for
  everything lazysite is alive to serve.

Tier 2 - web-server diagnostics (optional, owner-wired)
: what only the web server can see: SUCCESSFUL static-asset serves, CGI
  hard-crashes (compile/exec level - "End of script output before headers"),
  and proxy-layer failures (nginx 502/504, TLS). A system cannot log its own
  absence; this tier inherently belongs to the server owner, who has root -
  i.e. already has access by definition. It is episodic troubleshooting, not
  a manager-facing feature. The SM139 environment debs install as root ONCE
  and wire this properly at package-install time (log ACL + logrotate
  inheritance, LAZYSITE_ACCESS_LOG env); unpackaged hosts follow a documented
  grant. The stats page consumes it as `source: server-log` enrichment
  (asset counts, AH-code error categories) whenever it happens to be
  readable - useful, never required.

## Alternatives rejected

- JS beacon: blocked by ad-blockers/no-JS, adds client weight, worse privacy.
- Keep server-log parsing + packaged wiring (SM139 doing the ACL/env work):
  fixes setup on OUR hestia deb only; still topology-dependent and misses
  nginx-served entries. Retained only as the enrichment path.

## Increments

1. **Access recorder** *(shipped 0.6.8)* - local subs in the processor
   (ADR 0001: module-free) wired at the output chokepoints (output_page /
   not_found / forbidden / serve_403, cache-hit flag, manager channel), field
   sanitisation, anonymise-at-write, daily files + retention prune, the
   first_party off switch, and the die-guard 500. Bench gate held.
2. **stats.pl first-party source** *(shipped 0.6.8)* - scan aggregates
   access-*.jsonl (headline human-only, manager channel excluded); server-log
   is the fallback; both outputs carry `source`.
3. **AI export** *(built 2026-07-10)* - export_stats / analyse_visitors
   ingests first-party files into the same day-bucket cache via per-file
   byte offsets (v2 cache; append-only day files make this trivial); shared
   _export_assemble; `source` in the export. CHANNEL DECISION: form-handler
   stays standalone/module-free by design and dav has its own audit - no
   recorder wiring until a concrete consumer needs those channels; the
   format's `ch` field already accommodates them.
4. **Docs** *(done 2026-07-10)* - manager.md, ai-briefing-stats.md, plugin
   --describe, the stats page hint. SM139's hestia deb treats web-server log
   access as optional tier-2 enrichment, never a requirement.

## Open questions

- Do bad-url-blocker and stats share the feed later? (blocker currently keeps
  its own store; a shared feed would halve the writes - candidate for a
  follow-up, not increment 1.)
- Unique-visitor definition under anonymise-at-write (daily salt for a
  same-day distinct count without retaining identifiers?) - proposal: yes,
  daily-salted hash, documented as "distinct daily visitors".
- retention_days default (90?) and a size guard (cap file count) for
  high-traffic sites.
