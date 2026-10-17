---
id: SM1151
title: "SM1151: the dev server answers connections side by side"
subtitle: "Each connection is handled in a forked child, up to eight at once, so a page's parallel requests stop queuing behind one accept loop."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-17
raised-by: lazysite-sites agent (oom-lab), accepted by the release manager 2026-10-17
area: dev tools
status-note: "SHIPPED on n642: tools/lazysite-server.pl; t/unit/tools/82. SM1082 Q4, oom-lab P5."
---

# What happened

The oom-lab measured the dev server's per-request cost (P5, "the 200 ms before
an Odoo call starts") and found its timings included waiting: the server took
one connection at a time, so a page's parallel requests queued behind the one
accept loop. SM1082 listed the fix as Q4: "The dev server forks per connection
(P5, dev only), so parallel reads stop queuing and the lab's timings are real."

# What shipped

`tools/lazysite-server.pl` forks a child per connection, with a cap of eight
at once (`LAZYSITE_DEV_MAX_CONN` overrides it; the browser's own parallelism is
six). When the cap is reached the accept loop waits for a child to finish;
finished children are reaped on each accept. If a fork fails the connection is
served in the parent, as before.

Two details keep the children from hurting each other:

- A child leaves with `POSIX::_exit`, so the END block does not remove the
  browse cache or the error file the parent and the other children still use.
- The stderr capture file is named for the child's pid. It was named for the
  parent's, so two children would have shared and truncated one file.

Dev only: the CGI, FastCGI and pool paths are untouched.

t/unit/tools/82 uses a processor that sleeps one second. Two requests finish in
under 1.7 s (a serial server takes 2); with the cap at 2, four requests take
between 1.9 and 3.5 s (two waves; a serial server takes 4, an uncapped one 1).
