---
id: SM1455
title: "SM1455: the bad-URL guard reads the request's path behind Apache"
subtitle: "The auth wrapper took its path from REDIRECT_URL, which Apache does not set on the routes into it, so the blocker checked / for every request and never counted a probe."
brand: plain
standard-margins: true
status: candidate
raised: 2026-11-16
raised-by: "the 0.17.0 field walk (T3.1), diagnosed by the developer"
area: security
status-note: "OPEN. Target 0.17.1 stable. One line in lazysite-auth.pl and a real-Apache test."
---

# What happened

On the 0.17.0 field walk the bad-URL blocker counted nothing: eleven requests for `/wp-login.php`
from one address were all answered 404, never 403, and no hit file was written. The cache
directory was writable by the CGI's user, and the request reached the auth wrapper.

# Why

`lazysite-auth.pl` sets `my $uri = $ENV{REDIRECT_URL} // '/'`. Run against a real Apache 2.4 with
the Hestia templates' two routes into the wrapper - the SM797 source-type `RewriteRule ... [PT]`
and `FallbackResource` - REDIRECT_URL is unset on both; REQUEST_URI carries the path. The guard
therefore asked whether `/` is a probe, for every request. The line predates the blocker. The
pool's front door and the processor fall back to REQUEST_URI and are not affected; nothing else in
the wrapper reads `$uri` but its log lines. `t/integration/14` passed because it sets REDIRECT_URL
itself.

# What it costs

The blocker has not counted a probe that reached a site through the auth wrapper behind Apache.
Nothing was exposed by it: access rules are decided in the processor, which reads the right path.
A hardening that was believed on was off.

# The request

R1
: The wrapper's path is REDIRECT_URL, else REQUEST_URI without its query, as the front door's is.

R2
: A real-Apache test (the harness t/integration/40 uses) sends probes by both routes and is
  refused at the threshold; t/integration/14 stops setting REDIRECT_URL where Apache would not.
