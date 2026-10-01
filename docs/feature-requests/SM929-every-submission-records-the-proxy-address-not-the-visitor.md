---
id: SM929
title: "SM929: every submission records the proxy's address, not the visitor's"
subtitle: "`_ip` reads 10.2.30.177 on all nine stored enquiries on a customer site - a private RFC1918 address, the front proxy. The field that exists to identify where a submission came from identifies our own infrastructure, identically, on every row, on every site behind the proxy. An address that is always the same is worse than no address, because it looks like information."
brand: plain
standard-margins: true
status: shipped
raised: 2026-09-30
raised-by: site agent, while assessing whether nine stored enquiries were genuine (0.15.0)
area: forms
status-note: "SHIPPED (PENDING ref) 2026-10-01: ONE DEFINITION OF THE REQUEST ADDRESS, `Lazysite::Util::request_address`, AND EVERY READER OF A VISITOR ADDRESS GOES THROUGH IT. The population was surveyed rather than assumed and it is NOT the four this filing names: FORTY-FOUR reads across NINE files, ten driving a decision and thirty-three going on the record - the stored `_ip`, the audit actor column on auth/MCP/OAuth/manager-api/form paths, the login and form rate limits, the bad-URL blocker, the DAV transport limiter, the notification email, the daily visitor hash and `client_ip`. THE RULE IS THE RIGHTMOST HOP A TRUSTED PEER DID NOT CONTRIBUTE, not the first, for the measured reason recorded below. TRUST BASIS: `trusted_proxies`, a named list on the Config page (config-read + config-set + SITE_SCHEMA, with t/lint/18 holding the three in parity), defaulting to the RFC1918 ranges. `auth_proxy_trusted` WAS READ AND RULED OUT rather than assumed unsuitable: it is a boolean about X-Remote-* auth headers with no hop check at all (SM794), so overloading it would put two unrelated trust decisions behind one switch. ABSENT AND EMPTY BOTH MEAN THE DEFAULT, which is a decision and not a shrug: the field ships empty and pressing Save on the Config page WRITES empty (SM782 names the same shape for backup_retention), so reading empty as `trust nothing` would have turned the feature off for any site whose operator merely saved the page. `none` is the one spelling that turns it off; a /0 range is REFUSED because a trust set matching every caller is the fault being removed. THE COMPATIBILITY PROPERTY THAT MADE 44 CALL SITES SAFE TO CHANGE AT ONCE: with no forwarded header every one of them returns exactly what it returned before - REMOTE_ADDR, verbatim, not canonicalised. FIVE READS DELIBERATELY STAY ON REMOTE_ADDR and are a ledger rather than a residue (t/lint/206): the no-password account gate and the four plaintext-transport gates ask whether the PEER is this machine, which is a fact about the connection - a forwarded address that could unlock a passwordless login or make the engine accept Basic credentials in clear would be the worst place in the system to start trusting one. That lint also asserts the peer VALUE is what the peer question is asked of, which a sabotage forced: counting the reads alone let the DAV loopback test be switched to the visitor address with the `my $peer` line still standing - two assertions covering one claim. THE OTHER HALF IS THE FRONT END, and without it the engine half achieves nothing on a fronted site: the shipped nginx proxy templates set ONLY `Host` and never sent the visitor at all, so there was no header to read however the engine chose to read it. They now send `X-Forwarded-For $proxy_add_x_forwarded_for`, every Hestia template revision moves to 2026-10-01 (t/lint/135: one release is one revision), and the rollout table's VHOST column is therefore how an operator sees which sites still need a rebuild - the SM283 lesson, applied. UPGRADE.md states both operator steps. ADR 0001 keeps the render path module-free so the processor carries a PINNED COPY, with t/lint/205 holding the two identical clause by clause; t/lint/39 refused the first version of it, because the private-range default was a file-scoped `our` BELOW the main body and is therefore EMPTY when a request is served - the same shape that made SM922's system-page table silently do nothing, caught by a lint this time rather than by a sweep. It is a sub in both copies. The two readers of the setting are held to the same answers by t/unit/processor/84, because resolve_site_vars cannot tell an empty `trusted_proxies:` from an absent one and a disagreement there would have been invisible. Thirteen sabotages, thirteen refusals. WHAT THIS CHANGE DOES NOT DO, said plainly: (1) the ruling also asked whether THE STORE SHOULD ANONYMISE ON THE WAY IN, as the stats plugin's visitor log does - that is left open and needs a ruling of its own, and it matters MORE now than when the ruling was taken, because a fronted site stops recording one private constant and starts recording real visitor addresses, which is personal data where the proxy's address was not; UPGRADE.md says so where an operator will read it before enabling anything. (2) Dropping the field was never ruled and is not done. (3) A site whose vhost has not been rebuilt keeps recording its proxy, and no engine change can reach that. MEASURED ON THE LIVE STACK 2026-10-01 BEFORE ANY BUILD, AND THE MEASUREMENT CORRECTS THIS FILING'S OWN RECOMMENDATION. A one-off probe page (nocache, body CLIENT_IP_BEGIN[% client_ip %]CLIENT_IP_END) on sites.lazysite.io, deleted after three measurements: (1) an ordinary request rendered 81.220.87.98, a PUBLIC address, so a forwarded-for header does reach the engine even though nothing in this repo sets one - both Hestia proxy templates set only `proxy_set_header Host $host;`; (2) api.ipify.org returned that same 81.220.87.98, so on an ordinary request the first hop is genuinely the caller; (3) with `-H 'X-Forwarded-For: 203.0.113.7'` THE PAGE RENDERED 203.0.113.7. A VISITOR CAN THEREFORE CHOOSE WHAT `client_ip` SAYS, TODAY, ON A LIVE SITE - which is not a future design question but a present exposure: processor:7716 takes the first hop whenever the header is present, and the comment above it calls that value 'the original client behind a reverse proxy' while the sanitiser it applies defends only against markup injection, not against the address being invented. SO THE BUILD TAKES THE RIGHTMOST HOP NOT CONTRIBUTED BY A TRUSTED PEER, NOT THE FIRST. The bullet below (take the first address, not the last) is right for a proxy that REPLACES the header and wrong for one that APPENDS, because a caller-supplied value then arrives AHEAD of the true one and the first hop is the forged one - exactly what (3) measured. The rule that holds under every shape consistent with the measurements: if REMOTE_ADDR is not in the trusted set, use REMOTE_ADDR and ignore the header entirely; if it is trusted, walk the chain FROM THE RIGHT and take the first address that is not itself trusted; fall back to REMOTE_ADDR when that leaves nothing. WHAT I DID NOT ESTABLISH, and why it does not change the design: whether sites.lazysite.io is fronted by the proxy or served directly - reading a stored `_ip` would have settled it and that read was refused as personal data. Served directly, REMOTE_ADDR is the public caller, is therefore NOT in the trusted set, the header is ignored, and (3) is defeated. Fronted, measurement (1) proves the front end SETS the header - no header was sent and a public address still rendered, where the absent-header fallback at processor:7718 would have shown the private peer - so the rightmost hop is the one the trusted proxy contributed. That same reasoning excludes the one shape the right-hand walk would NOT fix: a trusted proxy that forwards a caller's header without adding to it. TRUST BASIS RULED 2026-10-01: A NAMED LIST IN SITE SETTINGS, DEFAULTING TO THE RFC1918 RANGES - not `auth_proxy_trusted` reused on an assumption, which the ruling below refused to make. RULED 2026-10-01: ONE DEFINITION OF THE REQUEST ADDRESS, AND ALL FOUR READERS ADOPT IT IN ONE CHANGE. Not the store alone - the filing named the thing to measure first and the measurement came back worse than it supposed. FOUR PLACES KEY ON REMOTE_ADDR, which behind the shipped proxy is one constant for every visitor a site will ever have: the stored `_ip` (Handlers.pm:1349 from form-handler.pl:255), the FORM rate limit (form-handler.pl:213), the LOGIN rate limit (lazysite-auth.pl:282), and the BAD-URL AUTO-BLOCKER (lazysite-auth.pl:243 -> BadUrl::record_and_check). THE BLOCKER IS AN AVAILABILITY FAULT, NOT A DATA-QUALITY ONE: its default is enabled (`bad_url_block` // 'enabled'), its threshold is 10 bad URLs in 3600s, it has NO private-range exclusion, and the address it blocks is the one it counted - so ten scanner hits from anywhere in an hour write the proxy's address into bad-url-blocked.json, after which `is_blocked` denies every request from every visitor to that site. Not observed in the field; it follows from four lines and the field conditions that produce it are ordinary. The two rate limits share one bucket between all visitors by the same mechanism, which is a lesser version of the same fault. AND THE ENGINE ALREADY HAS THE OTHER ANSWER: processor:7674 builds the `client_ip` template variable from the FIRST HOP of X-Forwarded-For, unconditionally, with no trust check, sanitised to IP characters - while docs/architecture/security.md:199 says proxy headers are NOT trusted. So the engine holds two contradictory positions on who the visitor is, and the unconditional one is the one exposed to authors. Unifying therefore removes an untrusted read as well as adding a trusted one. WHAT THE BUILD MUST SETTLE BY MEASUREMENT RATHER THAN ASSUMPTION: which trusted-proxy notion to key on. The filing suggests the private ranges the engine ships behind, and names `auth_proxy_trusted` as a candidate while explicitly refusing to assume it is the right one - that question is open and belongs in the build, because reading a caller-supplied header without a trust check would let any visitor write any address into the store, the rate limiters and the blocker, which is worse than the present state rather than better. Also to settle there: whether the store anonymises on the way in, as the stats plugin's visitor log already does. NOT RULED HERE: dropping the field, which the filing offered as its alternative."
---

# Measured

Nine enquiries on a customer site, 13 to 28 September, from at least two different
organisations and six unrelated spam campaigns. Every one records:

    "_ip": "10.2.30.177"

A private address. The site resolves publicly to a different address, so
10.2.30.177 is the front proxy talking to the application. The same value appears
on test submissions to edge.explore, and a second customer site records its own
proxy address the same way on every row of its contact store.

So `_ip` is **constant across every submission a site will ever receive**.

**Grade: measured on three sites, one of them ours.** The reporter checked whether
the address was routable before drawing a conclusion, which is the step that
turned this from a finding about the traffic into a finding about the engine.

# What it costs

**Triage.** The reporter was asked whether nine enquiries were junk. A shared
source address across all nine is normally strong evidence of one origin; here it
is evidence of nothing, and they nearly reported it as a signal. An operator
without the habit of checking would reach the opposite conclusion about their own
traffic.

**Anything per-address.** The Submissions page shows the address. The bad-URL
blocker and the login rate limiter are both documented as working per address.
Whether they read the header separately has not been established - but if any of
them sees what the form handler sees, it is counting one address for the whole
world. **That is the part of this filing to measure first**, because a rate
limiter keyed on a constant is a different severity from a misleading column.

**Abuse handling.** An operator who wants to block or report a source has nothing
to act on.

# What it should read

The forwarded-for header the proxy sets, falling back to `REMOTE_ADDR` when there
is no trusted proxy in front. That needs the usual care and none of it is novel:

- take the **first** address in `X-Forwarded-For`, not the last;
- only when the immediate peer is a **trusted** proxy, which this install can know
  - the address is in the private ranges the engine already ships behind;
- and keep `REMOTE_ADDR` when nothing is trusted, so a directly-served site is
  unaffected.

A forwarded-for header is caller-supplied, so the trust check is the whole
security of it: reading the header unconditionally would let any visitor write
whatever address they liked into the store, which is worse than the present state
rather than better. The engine already has a trusted-proxy notion for the
`auth_proxy_trusted` read that 0.15.1 restructured - whether it is the right one
to reuse here needs checking rather than assuming.

The anonymisation the stats plugin applies at write time is the model for what to
do with the result: the visitor log anonymises on the way in, and the submission
store could do the same rather than storing a raw address.

# Why it is worth doing rather than dropping the field

An address that is always the same is worse than no address: it looks like
information. A reader of the Submissions page sees a column of identical values
and concludes something about their traffic. Either the field carries the visitor,
or it should not be shown.

# How it was found

Assessing whether a customer's nine stored enquiries were genuine. Six were
commercial spam and three were real - one of them a production support case naming
a systemd exit status, unanswered for sixteen days because the form has no
delivery beyond local storage. The address field was the first thing reached for
to tell the campaigns apart, and it could not.

# Measured before building, 2026-10-01

The ruling asked for the trusted-proxy question to be settled by measurement
rather than assumption. A probe page on sites.lazysite.io carried nothing but
`CLIENT_IP_BEGIN[% client_ip %]CLIENT_IP_END` on a `nocache: true` page, and was
deleted when these three were taken:

| # | request | `client_ip` rendered |
| - | ------- | -------------------- |
| 1 | `curl -s https://sites.lazysite.io/diag-sm929-client-ip` | `81.220.87.98` |
| 2 | `curl -s https://api.ipify.org` (the same caller, for comparison) | `81.220.87.98` |
| 3 | the same page `-H 'X-Forwarded-For: 203.0.113.7'` | `203.0.113.7` |

**(3) is the finding.** A forwarded-for header reaches the engine (1), and on an
ordinary request its first hop is really the caller (2) - but a caller who sends
the header chooses the answer (3). `client_ip` is a visitor-controlled value on a
live site today, and the comment above `processor:7716` describes it as the
original client while the sanitiser beside it defends only against markup in the
rendered output.

So **the recommendation above is wrong in one bullet**: the first hop is the right
one to take only when the proxy *replaces* the header. Where it *appends*, a
caller-supplied address arrives ahead of the one the proxy added, and the first
hop is the forged one. The build takes **the rightmost hop not contributed by a
trusted peer**:

- `REMOTE_ADDR` not in the trusted set - use `REMOTE_ADDR`, ignore the header;
- `REMOTE_ADDR` trusted - walk the chain from the right, take the first address
  that is not itself trusted;
- nothing left - `REMOTE_ADDR`.

Whether sites.lazysite.io is fronted or served directly was **not** established -
reading a stored `_ip` would have settled it and that read was refused as personal
data - and the rule above is correct either way. Served directly, the public peer
is untrusted, the header is ignored, and (3) is defeated. Fronted, (1) shows the
front end sets the header itself, because no header was sent and the absent-header
fallback would have rendered the private peer instead of a public address; so the
rightmost hop is the proxy's own contribution. The one shape that would defeat a
right-hand walk - a trusted proxy that passes a caller's header through without
adding to it - is excluded by (1) for that same reason.

**The trust basis is a named list in site settings, defaulting to the RFC1918
ranges** (ruled 2026-10-01), rather than reusing `auth_proxy_trusted` on the
assumption that it means the same thing.

# Related

[[SM216]] (the quarantine scoring that runs on the same submission), [[SM930]]
(the own-domain rule, from the same nine submissions), [[SM925]] (why those nine
sat for sixteen days),
[[reference_lazysite_stats_gotchas]], [[feedback_uniform_field_not_constant]].
