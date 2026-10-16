---
id: SM1099
title: "SM1099: an anonymous request does not fill the web server's error log"
subtitle: "The auth wrapper logs a request's cookie state at DEBUG, and reads the site's log_level as the processor does."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-16
raised-by: release manager, 2026-10-16
area: auth
status-note: "SHIPPED on n608: lazysite-auth.pl; t/unit/auth/61."
---

# What happened

The release manager, 2026-10-16: the Apache error log "filled with hundreds of
MB of":

    [2026-10-16 19:47:47] [INFO] [auth] [/] auth: no cookie

Every request passes through `lazysite-auth.pl`, and its log lines go to
stderr, which is the web server's error log. It logged one INFO line for
every signed-out request ("auth: no cookie") and one for every signed-in
request ("auth: cookie valid"), so the log grew at the rate of the site's
traffic. The processor has read `log_level` from lazysite.conf since it was
added; this wrapper never did, so a site could not turn it down short of an
environment variable in the web server's config.

# What shipped

- "auth: no cookie" and "auth: cookie valid" are DEBUG. A visitor signed in
  or signed out is the normal case, not an event. Refusals (malformed,
  signature, expired and the rest) keep their WARN.
- The wrapper reads `log_level` from lazysite.conf before its first log line.
  `LAZYSITE_LOG_LEVEL` still wins, as in the processor.

t/unit/auth/61 drives the real wrapper as a CGI request: nothing on stderr at
the default level; `log_level: DEBUG` brings the line back; the env override
wins.

# For a site already affected

Until 0.15.7 is deployed, `SetEnv LAZYSITE_LOG_LEVEL WARN` in the site's
Apache config silences these lines. The log already written can be truncated
or rotated by the operator.
