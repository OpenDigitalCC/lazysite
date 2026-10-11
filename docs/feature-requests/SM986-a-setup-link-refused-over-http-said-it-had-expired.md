---
id: SM986
title: "SM986: a setup link refused over plain HTTP said it had expired"
subtitle: "The claim page gave the transport refusal the answer for a bad or used link, so the person asked for another link, which failed the same way."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-11
raised-by: the dev inbox (2026-10-11, a local 0.15.3 site reached over http on a LAN); WORK-PLAN-0154 P7
area: auth
status-note: "SHIPPED (PENDING): the claim's transport refusal redirects with error=https and the claim page says a password can only be set over HTTPS; a bad or used link keeps the generic answer (t/unit/auth/26)."
---

# What was wrong

`handle_claim` (lazysite-auth.pl) refuses to set a password when the peer is
not the machine itself and `HTTPS` is not set. The refusal is right; it
redirected to `/claim?u=NAME&error=1`, the same as a bad, used or expired
link, and the claim page (starter/lazysite/templates/system/claim.md) said
"That setup link is invalid or has expired ... ask your site operator for a
new one". The new link failed the same way, and the operator had no sign that
the transport was the cause. The log held it: `claim over plaintext refused`.

# The fix

The transport refusal redirects with `error=https`, and the claim page says
that a password can only be set over a secure (HTTPS) connection, that the
link has not been used, and to open it with an `https://` address. Every other
failure keeps `error=1` and the generic answer.

It reveals nothing: the refusal is taken before the link or the account is
looked at, so a real link, a bogus one and a name with no account get the
same answer.

The shipped claim page is in the code bucket (SM201) and is refreshed by
every upgrade. A site that overrides it with its own `claim.md` keeps its own
text, and there `error=https` reads as the generic answer, as before.

# Tests

t/unit/auth/26: over plain HTTP from another machine, a real link, a bogus
link and an unknown account all redirect to `error=https`, identically, and
set nothing; over HTTPS a bogus link is still `error=1` and the real link,
untouched by the refusals, works; the claim page shows each answer.
