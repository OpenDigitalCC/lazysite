---
id: SM1471
title: "SM1471: the dev server runs the Odoo endpoint as a pooled site does"
subtitle: "The dev server starts a new perl for every call to the Odoo endpoint, and starts neither the warm-fork parent (SM1226) nor oomd (SM1164), so a lab on it measures a cost a pooled site does not pay."
brand: plain
standard-margins: true
status: candidate
raised: 2026-11-17
raised-by: "a field report from a lab site (archived at inbox/archive/2026-11-17-dev-server-cannot-start-resident-odoo-parts.md)"
area: performance
status-note: "CANDIDATE, filed 2026-11-17. Nothing built. Target 0.17.x edge. The report's claims are checked against the code below (confirmed, one corrected, measurements not checkable). Questions for a ruling at the end: which of R1 and R2 is wanted, and the warm-fork parent's gate."
---

# What was reported

A lab site on the dev server (`tools/lazysite-server.pl`) with the Odoo extension, reading from an
Odoo 18 instance. Every call to `/cgi-bin/lazysite-odoo.pl` is a new perl process. The reporter's
measurements, which this filing records as theirs and did not repeat:

- `?csrf=1` (no Odoo work): 133 ms CPU, 163 ms wall at load 17. The server adds about 30 ms over
  running the script directly (310 ms against 278 ms, interleaved, 15 pairs).
- A whole read costs 470 to 550 ms CPU. Compiling the engine and the Odoo extension is about 120 ms
  of it (`lazysite-odoo.pl` 42 ms, `Lazysite::Odoo` 76 ms), before OOM is loaded at all.
- 166 modules are loaded in each call.

# What the code says

Each claim in the report was read against the tree at d886cf350.

Confirmed
: - The server answers the endpoint with `qx(perl $script)`: line 883 for a call with no body, and
    `cat FILE | perl $script` just above it for a POST (tools/lazysite-server.pl).
  - It forks a child per connection (SM1151, line 491), so the process cost is per request, not per
    connection.
  - The endpoint runs direct, with no auth wrapper in front, since SM1181 S5 (`self_verifying`, line
    632). So the second program the lab once paid for is gone, and what remains is the one perl start
    and compile.
  - SM1226's warm-fork parent is started by lazysited as the `odoo-endpoint` service, and only where
    the site has a pool conf (`Service::OdooEndpoint::wanted` asks `Lazysite::Paths::pool_conf_for`,
    which reads `/etc/lazysite/pools/*.conf` for a `DOCROOT=` matching the site). A site on the dev
    server has none. Its only clients are the pool's front door and the split templates'
    endpoint location; the dev server is neither (grep of the server for pool, warm, oomd and
    lazysited finds only SM1151's comment).
  - SM1226 records 116 ms to 17 ms for an endpoint call on its bench host, through the pool and
    with oomd answering (its status-note).
  - `Lazysite::WarmFork::Wire::request( $socket, \%params, $body )` exists and returns
    `{ connected => 0 }` when nothing reached the parent, which is SM1226's W7 (the CGI runs
    instead). The dev server could call it with the CGI environment it already builds.

Corrected
: - "Both are started by lazysited" is true, but they have different gates. oomd (SM1164) is wanted
    when the Odoo extension is on, `odoo_daemon` is `on` or `required` and oomd is installed. It
    needs no pool conf. A lab that runs lazysited for its docroot and sets `odoo_daemon: on` gets
    oomd answering the OOM share of a call even under the dev server: the extension's CGI reaches it
    through its socket. What the dev server cannot give is the warm-fork parent, and that is the
    120 to 160 ms the report is about. So R1 below is about the parent only.

Could not check
: - The timings, the load, the 30 ms the server adds and the module counts. They come from a harness
    and a host this build does not have. The 116 to 17 ms figure is SM1226's own record, not a
    measurement made for this filing.
  - Whether the reporter's lab runs lazysited at all. The dev server does not start it
    (`lazysited` is not named in the server).

# The requests

R1
: **The dev server hands the Odoo endpoint to the warm-fork parent when one is running, and runs
  the CGI when it is not.** For a request to `lazysite-odoo.pl` the server would build the CGI
  environment it already builds, ask `Lazysite::WarmFork::Wire::socket_for` for the site's socket,
  and call `Wire::request`. A parent that is not there (no socket, a refused connection) leaves
  the request to the CGI exactly as today; once the parent has taken a request it is not re-run
  (W7 and SM1226's rule for a write). Nothing else about the server changes. The parent has to be
  running for this to help, which is the question below.

R2
: **The dev-server section of the docs says what a lab's Odoo timing means.** docs/FEATURES.md,
  "The dev server" (line 1852), gains a sentence: a call to the Odoo endpoint on the dev server is
  a plain CGI, a new perl each time, and its timing is not what a pooled site shows; with
  `odoo_daemon: on` and lazysited running, the OOM share is the same as a pooled site's. This is
  the whole of the request if R1 is not wanted.

# Expected saving

As the reporter measured, not repeated here: about 120 to 160 ms per call (process start and the
engine and extension compile) on the lab host at load. SM1226's bench host recorded 116 ms to 17 ms
for an endpoint call. It does not touch the OOM share of the call (SM1472, SM1164).

# What a build must keep true

- The dev server stays a plain host. A lab with no parent running behaves as it does now.
- The parent holds code only and never a request or a credential (SM1226 W1 to W7). The dev server
  gives it the environment a CGI would have, so the identity variables a front end could carry are
  cleared by the parent as for any other client (W3). The dev server runs the bad-URL guard
  (`dev_bad_url`) before the call, as it does for the CGI today.
- A test that fails against the old code: the server answers an endpoint request through a stand-in
  parent on a socket, and answers the same request through the CGI when the socket is gone.

# Questions for a ruling

1. **The parent's gate.** SM1226 was ruled (2026-10-20) to run the parent only where a front end
   hands it a call, decided from the site's pool conf, with no setting. A dev-server site has no
   pool conf, so lazysited starts no parent for it and R1 would have nothing to call. Options:
   (a) leave the gate and R1 only calls a parent that someone started by hand, which makes R1 close
   to useless in a lab; (b) widen `wanted` so that a running dev server for the docroot counts as a
   front end (a fact the server could record in the site's `lazysite/run/`), still with no setting;
   (c) a documented one-line way to run a lab site behind a pool, so the existing gate applies and
   the dev server is not the front end at all; (d) R2 only. The build cannot choose between these:
   (b) reopens the 2026-10-20 ruling's "front end decides" rule, (c) is outside this server.
2. **Is the lab's timing worth a code change, or only a sentence?** The dev server is for
   development. If a lab's Odoo timing matters, R2 alone tells the reader what it measures.
