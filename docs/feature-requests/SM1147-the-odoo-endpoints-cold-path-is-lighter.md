---
id: SM1147
title: "SM1147: the Odoo endpoint's cold path loads only what it answers with"
subtitle: "`?csrf=1` and a request refused before it reaches Odoo no longer load Lazysite::Odoo, its Egress, its binding and field modules or OOM."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-17
raised-by: the lazysite-sites agent (P4), accepted by the release manager 2026-10-17 ("all rulings accepted"; SM1082 Q3)
area: odoo
status-note: "SHIPPED on n641: lazysite-odoo.pl _engine; t/unit/odoo/43. Measured: about 4 ms of 86 ms CPU per ?csrf=1 (see What shipped)."
---

# What happened

From the lazysite-sites agent, "The 200 ms before an Odoo call starts", 2026-10-17 (inbox/archive/2026-10-17-the-200-ms-before-an-odoo-call-starts.md), option P4:

> **Lighter cold path**, if P1 waits: load Lazysite::Odoo and OOM only on the
> branches that need them (`?csrf=1` and sign-out do not); see whether the wrapper
> can be skipped for this endpoint when it verifies the session itself (it is a
> surface that answers the anonymous visitor too). perhaps 50-100 ms

# What shipped

`lazysite-odoo.pl` loads the engine (`Lazysite::Odoo`, and under it Egress, the
binding and field modules, and OOM) through `_engine`, called by the branches that
reach Odoo. These answer without it: `?csrf=1`, the wrong method, a body that is
not JSON, an oversized body, and a sign-in or sign-out refused for its token.
A sign-out that passes its token still loads the engine, because it writes the call
record. The request's own work (the visitor, session and identity cookies, the
account's session) is done by the small modules it always used.

Measured with a fresh process per request, `taskset -c 0 nice -n 19`, child CPU
over 60 interleaved runs, on the shared host at load average about 10, for
`GET ?csrf=1` with the extension enabled:

```
before   85.8 ms CPU per run
after    81.8 ms CPU per run      (about 4 ms, 5 percent)
perl -e 1                          4.0 ms
require Lazysite::Odoo            49.2 ms   (most of it shared with what ?csrf=1 loads anyway)
require Lazysite::Manager::Plugins 72.2 ms
require Lazysite::Auth::Session    45.5 ms
```

Wall time on that host moves by more than the saving (median 158.7 ms before,
153.9 ms after, over the same runs), so CPU is the figure. The lab's estimate of 50 to
100 ms is not reached by deferring the engine: most of the cold cost of `?csrf=1`
is `Lazysite::Manager::Plugins` (the extension-enabled check, which pulls
`Manager::Common` and the auth modules) and `Lazysite::Auth::Session`, both of which
the request needs. Removing them from this path is a larger change to how an
extension's switch is read, and the resident worker (P1, SM1082 C3) removes the
whole start-up; neither is done here.

t/unit/odoo/43 runs the real endpoint in a fresh perl per case and lists `%INC` when
it has answered: `?csrf=1` and the refused requests hold no `Lazysite::Odoo`,
`Egress`, `Binding`, `Fields` or `Odoo::*`; a binding read, as the control, holds
them.
