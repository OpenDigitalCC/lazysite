---
id: SM747
title: "SM747: a site app reads live facts from Odoo, through named queries only"
subtitle: "A plugin holding one credentialed Odoo client per site, exposing declared named queries to page scripts and never a model or a method. Filed from the odoo-bridge draft; the OOM library ships as a package and is a dependency, not a copy."
brand: plain
standard-margins: true
status: candidate
---

# What is being asked for

A plugin - `odoo-bridge` - giving site data apps server-side access to a
configured Odoo instance, so an app such as the jpm stock-corrections portal can
show live facts (available stock per product, lot and location; sales-order
state; dispatch status) instead of working from exported snapshots.

The library it consumes, OOM, is plain Perl with no Moose or Moo, and every
dependency is either core or already packaged.

# The shape that makes it safe

The draft's central rule is the right one and should be treated as load-bearing
rather than as a default to be relaxed later:

**Named queries only. No raw model, method or domain passthrough to the browser,
ever.**

Site config declares each query as a model, a domain template, a field list and
typed parameters - `stock_on_hand(product_code)` resolving to a `stock.quant`
`search_read`. A page script calls the query by name over the existing data
endpoint conventions, and the plugin binds parameters server-side.

The alternative - letting a caller name a model and a domain - is an
arbitrary-read primitive against the business system, reachable from a page.
The whole value of this filing is that it never offers one.

# Requirements

| Ref | Requirement |
| --- | --- |
| OB1 | Per-site Odoo connection; credentials outside the docroot, never logged, never reaching a page script or the browser |
| OB2 | Named read-only queries declared in site config; parameters typed and bound server-side |
| OB3 | No raw model / method / domain passthrough from the browser, ever |
| OB4 | Caller gating through lazysite's native permission model, as data tables are |
| OB5 | Timeouts and a per-site rate cap; Odoo faults surface as clean JSON errors, transport errors as retryable ones |
| OB6 | Optional Odoo-credential login (`verify_credentials`) behind its own config switch |
| OB7 | OOM delivered as a versioned `.deb` (`libodoo-oom-perl`); the plugin pins a minimum version and never carries a copy of the code |

OB7 is settled: the release manager has confirmed OOM is a package and a
dependency of the plugin, the same as any other. **This repository cannot
install it** - that is an operator step whenever this is scheduled.

# Where it sits relative to the daemon

**Request-time, not [[SM666]].** As drafted this runs inside a request, and it
should stay that way for a first version. It is not a daemon module and does not
wait for the runtime.

But it shares the programme's hardest problem, and the sharing should be
deliberate rather than parallel: **it egresses from inside a request.** Per-site
rate caps, timeouts, credentials held outside the docroot, and an audit entry per
call are the same controls [[SM579]] is designing for the connector line. Those
should be designed once and used twice, not invented here and again there.

Two things follow. **OB5's caps and timeouts should be SM579's**, once SM579 has
them. And the periodic-refresh idea the draft supersedes - "was this order
validated in Odoo since the last export" - is a scheduler consumer, so a cached
or refreshed variant becomes natural once SM666 phase 1 exists. Neither is a
reason to wait.

# The error surface, learned from three passes

Whatever this returns to a caller must carry no host detail: no absolute path,
no driver or transport vocabulary, no echoed command, no upstream stack. That
rule earned itself the hard way across SM713, SM738 and SM739 - three leaks in
three passes, the third introduced by the fix for the second - and `t/lint/112`
now checks the source for it.

An Odoo fault is a **remote** system's error text, which is the same class of
problem one step further out: it is not ours, its wording is not stable, and a
caller building against it is building against a dependency. OB5 already
separates fault from transport, which is the right split; what it should add is
that the fault's own text is logged rather than returned verbatim.

# First useful queries

Available quantity by product, lot and location; sales-order and picking state
by S/O name; whether an order was validated in Odoo since the last export.

# Invocation modes (2026-09-03)

OB5's per-site rate cap is not this filing's to invent. [[SM579]] now carries
the rule for every outbound call - scheduled by the timer, invoked by a
logged-in user holding the capability, or backing a public service with input
the implementor has bounded - together with the caps that apply in all three.

An Odoo query is one of those calls. It takes SM579's modes, SM579's caps and
SM579's declaration, rather than a second implementation of the same controls
with a different name.

# Provenance

Drafted as `lazysite-plugin-filing.md` and filed 2026-09-03 at the release
manager's direction. The OOM library is at `/srv/projects/odoo/oom/`; nothing
here is built.
