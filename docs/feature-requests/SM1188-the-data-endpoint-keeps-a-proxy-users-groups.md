---
id: SM1188
title: "SM1188: the data endpoint keeps a proxy user's groups"
subtitle: "A trusted proxy that uses the default X-Remote-* header names now has its groups reach the data endpoint's table checks and write gate."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-19
raised-by: SM1181 S1 build, 2026-10-19 (n676)
area: data
status-note: "SHIPPED on n676: lazysite-data.pl; t/integration/273."
---

# What happened

The SM1181 S1 build found:

    the data endpoint deletes every `HTTP_X_REMOTE_*` before it reads groups.
    On a proxy site that uses the default `X-Remote-*` header names, a proxy
    user's groups therefore never reach the data endpoint's group checks.

It failed closed (fewer groups, never more). SM1137 made the data endpoint
honour a trusted proxy's user; the groups were lost under the default names
because the strip ran before the second read, and the configured names are the
fixed names by default. t/integration/272 renames the proxy headers, so no test
saw it. Reproduced on the base by t/integration/273: a table restricted to
`@staff` refused a proxy user whose `X-Remote-Groups` named Staff, and a marked
directory group's `manage_data` never reached the write gate.

# What shipped

lazysite-data.pl takes a trusted proxy's groups (and the groups for its write
capabilities) from the identity `request_identity` returned before the strip,
instead of reading again after it. The strip is unchanged for every request:
client-sent identity headers from an untrusted peer are still removed (SM1129).

Other surfaces that strip `X-Remote-*`, checked:

- lazysite-processor.pl `apply_trust_gate`: returns before stripping when the
  proxy is trusted; no fault.
- lazysite-manager-api.pl: strips only when the proxy is not trusted; no fault.
- lazysite-auth.pl: sets the headers from a verified identity; no fault.
- lazysite-mcp.pl (two places) and Manager::Domains `_anonymous_env`: render as
  an anonymous visitor on purpose; no fault.

t/integration/273 covers the default names from the trusted peer (served and
refused), the same headers from an untrusted peer (stripped), a cookie user, and
a write through a marked directory group.
