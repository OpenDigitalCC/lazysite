---
id: SM987
title: "SM987: the development server could not receive a form post"
subtitle: "Every native form posts to /cgi-bin/form-handler.pl, and tools/lazysite-server.pl answered it 404."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-11
raised-by: the dev inbox (2026-10-11, a staged 0.15.3 site shown on a LAN); WORK-PLAN-0154 P8
area: tools
status-note: "SHIPPED (0.15.5): the development server routes /cgi-bin/form-handler.pl to plugins/form-handler.pl, run directly as an installed site runs it, outside the auth wrapper (t/unit/tools/80)."
---

# What was wrong

`tools/lazysite-server.pl` chose its CGI by `^/cgi-bin/(lazysite-[\w-]+\.pl)`,
so a post to `/cgi-bin/form-handler.pl` fell through to the processor, which
answered "Page not found" with 404. A person trying a form on a staged site saw
"Could not send: Server returned 404". Reproduced with the server on loopback
(tmp/p8-live.pl): 404 before, the handler's own answer after.

# The fix

The routing decision is now `cgi_target_for` (a pure function, testable from
the modulino). `/cgi-bin/form-handler.pl`, exactly, runs
`plugins/form-handler.pl` - the file an installed site links into cgi-bin
(install.pl `post_install_steps`). It runs directly, not behind the auth
wrapper, as it does installed: the handler reads no identity from the request
(SM402). Nothing else in cgi-bin is newly reachable; `payment-demo.pl`, which
installs beside it, is left out because nothing asked for it.

# Tests

t/unit/tools/80: the form post reaches the plugin, directly; the
`lazysite-*` scripts route as before, behind the wrapper; other names and a
traversal reach the processor.
