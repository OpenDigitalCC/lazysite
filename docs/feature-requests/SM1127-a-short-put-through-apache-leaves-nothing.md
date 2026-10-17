---
id: SM1127
title: "SM1127: a short PUT through a real Apache leaves nothing behind"
subtitle: "A body shorter than its Content-Length, cut off or stalled, is tested through Apache's own layer to lazysite-dav.pl: nothing stored, no temp, nothing listed."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-16
raised-by: the 0.15.9 test-plan walk, row X12, 2026-10-17
area: release/tests
status-note: "SHIPPED on n628: t/integration/262, t/lib/DavTrace.pm. No engine change: the SM1114 SIGTERM path holds under Apache."
---

# What happened

Row X12 of the 0.15.9 walk (SM1114, a failed PUT leaves nothing) was skipped:

> The engine cannot be reached with a short body from outside: the front nginx
> deals with it first.
>
> - curl over HTTP/2 with `Content-Length: 1000` and 100 bytes: `400 Bad Request`
>   in nginx's own page, in 0.1 s.
> - HTTP/1.1 (raw TLS socket, 100 of 1000 bytes, then wait): no response in
>   120 s.
> [...] This needs a request that reaches Apache directly (on the host, or a
> test in the suite).

t/unit/dav/33 drives lazysite-dav.pl with a closed stdin. The live front's
Apache layer, which sits between a cut-off client and the script, was never
exercised.

# What shipped

t/integration/262 starts a real Apache (mod_cgi, `ScriptAlias /dav` as in
`installers/hestia/lazysite-cgi.tpl`, `Timeout 3`) and speaks to it over a raw
socket. It skips cleanly when apache2 or its modules are missing. A control
PUT of a whole body is stored (201). Then a PUT with `Content-Length: 1000`
and 100 bytes, in two cases: the client half-closes (`shutdown SHUT_WR`), and
the client stalls. For each: nothing at the target, no `name.tmp.<pid>`,
PROPFIND lists neither, and the client is not told it worked.

What Apache does, as measured:

- It answers a body that ends short itself: `400 Bad Request` at once on a
  half-close, `408 Request Timeout` after its `Timeout` on a stall. Both are
  Apache's pages; the engine's own 400 ("ended after N of M bytes") is
  discarded and never reaches the client. The test asserts a 4xx, not the
  engine's text; the engine's text is t/unit/dav/33.
- On a half-close it ends the CGI immediately (AH01225 in its error log),
  usually before perl has loaded the script, so the engine often does not run.
- On a stall the engine runs for the whole Timeout with its `.tmp.<pid>` on
  disk, then Apache ends it with SIGTERM. The SM1114 handler exits, the END
  guard removes the temp, and the directory is clean. t/lib/DavTrace.pm (a
  start and an end line per run, loaded through PERL5OPT) shows every start
  has its end. Without the SIGTERM handler the same test fails with the
  temp left behind, so it tells the two apart.

No defect: the SIGTERM path SM1114 meant to cover works under Apache. SIGKILL,
which Apache sends only if a CGI ignores SIGTERM, cannot be caught; the
engine's one-hour sweep of stale `name.tmp.<digits>` (SM1114) covers that.

The walk's HTTP/1.1 stall got no response in 120 s because the live front
waits longer than this test's 3 s `Timeout` (nginx and Apache defaults are
60 s each); the shipped Apache templates set no `Timeout`.
