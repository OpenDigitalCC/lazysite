---
id: SM1048
title: "SM1048: a domain without sign-in pages uses the engine's"
subtitle: "SM201's fallback covered login and claim; /forgot, the login page's own link, and /logout, where signing out lands, 404ed on a domain whose content root had no copy."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-12
raised-by: inbox 2026-10-12, what a site partner cannot do while building a site (P-8)
area: auth
status-note: "SHIPPED (PENDING): forgot and logout join SM201's system pages, with protected defaults under lazysite/templates/system/ held equal to the seeded pages; lazysite check probes them (t/integration/207)."
---

# The report

P-8: "`/login`, `/claim` and `/forgot` return 404 on a domain whose content root
lacks them, while the primary serves them. Protected pages then redirect to a
404." Asked: "Fall back to the engine's system pages when the domain has none."

# What the reproduction showed

t/integration/207 builds a fresh install (the starter tree), removes every root
copy of the sign-in pages, adds a domain whose content root has none, and asks
for each page with that domain's Host. On main:

| Page | Main | Now |
| --- | --- | --- |
| /login | 200, the protected default (SM201) | 200 |
| /claim | 200, the protected default (SM201) | 200 |
| /forgot | 404 | 200, the reset page |
| /logout | 404 | 200, the signed-out page |
| a protected page, signed out | 302 to /login, which is served | the same |

So on main the processor already serves /login and /claim on such a domain;
/forgot and /logout were not in SM201's set. **The /login and /claim 404s the
partner saw on edge (0.15.4) are not reproduced here.** The same code ships in
0.15.4, so they come from something in front of or around the processor on that
instance - its web-server routing, a missing `lazysite/templates/system/` (which
`lazysite check` reports as a FAIL or WARN), or a rule on the domain root. What
would settle it: the status and the component that answered (the processor's
log line for the request, or its absence) for one `/login` on that domain.

# The fix

`forgot` and `logout` join the fixed set in `%SYSTEM_PAGES`
(lazysite-processor.pl), and `starter/lazysite/templates/system/` ships a
protected default of each - copies of the seeded `starter/forgot.md` and
`starter/logout.md`, which stay seeded at the primary's root because SM939 keeps
them on a bare install. Test 207 holds each default equal to its seeded page.
`lazysite check` probes the two with the other five.

The set stays fixed: a missing ordinary page still 404s.

# Tests

t/integration/207; t/tools/04 (the check's fixtures carry the two defaults).
Sabotage: the set without forgot and logout fails 207's tests 13-18.
