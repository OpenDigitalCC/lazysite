---
id: SM1182
title: "SM1182: under the one-rule templates a form POST reaches the form handler"
subtitle: "The front door's dispatch list named only lazysite-*.pl, so /cgi-bin/form-handler.pl (and payment-demo.pl) fell to the processor as a page miss."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-19
raised-by: SM1181's review, "Found in passing, not C2's"; release manager, 2026-10-19 ("verify and fix now")
area: front door
status-note: "SHIPPED on n669: lib/Lazysite/FrontDoor.pm and lazysite-processor/front-door.pm rule 1b; t/integration/289; parity cases in t/lint/42."
---

# What happened

SM1181's review, section "Found in passing, not C2's", said:

> Under the one-rule templates `/cgi-bin/form-handler.pl` does not match the front
> door's `lazysite-[a-z-]+.pl` pattern, so it appears to fall to "page miss" and
> reach the processor, not the form handler. Read, not tried.

Tried, and reproduced. `install.pl` links `plugins/form-handler.pl` and
`plugins/payment-demo.pl` into cgi-bin under their own names (the two cgi-bin
links SM1142 describes), and every native form posts to
`/cgi-bin/form-handler.pl`. The one-rule templates (nginx, Apache, and the pool
under both) send every URL to the front door, whose dispatch is an allow-list of
`lazysite-[a-z-]+.pl`. A POST to `/cgi-bin/form-handler.pl` through the pool
front door came back `404 Not Found` with `Page not found:
/cgi-bin/form-handler.pl`: the processor's page miss. The form was never
delivered. `/cgi-bin/payment-demo.pl` failed the same way. Only these two
plugins are linked into cgi-bin; every other cgi-bin script is `lazysite-*.pl`
and was already named.

# What shipped

Both implementations of the routing table (`Lazysite::FrontDoor::route`, used
by lazysite-front.pl, and the module-free copy in the processor's front-door
part) gained one rule beside the named-surface rule: exactly
`/cgi-bin/form-handler.pl` and `/cgi-bin/payment-demo.pl` are routed to their
own script, unwrapped (the handler reads no identity, SM402; the classic
templates run them direct too). The list stays an allow-list of names. A
made-up `/cgi-bin/x.pl`, or `form-handler.pl.bak`, still reaches nothing.

t/integration/289 drives a pool worker with the front door on and a cgi-bin made
as install.pl makes it: a form POST returns the handler's own JSON answer, a
page still renders and a miss is the engine 404, payment-demo runs, and an
executable `x.pl` is not run on GET or POST. It fails on the base (the form POST
and payment-demo cases) and passes now. t/lint/42 gained the three cases so the
two copies cannot drift.
