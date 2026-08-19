---
title: "SM402: the form handler tags submissions with a header nobody verified"
subtitle: "form-handler.pl records _auth_user from HTTP_X_REMOTE_USER, but it is not behind the auth wrapper - so that header is whatever the client sent. The attribution on a stored submission can be set by the submitter."
brand: plain
standard-margins: true
status: shipped
status-note: "FIXED 2026-08-19, AND THIS FILING WAS WRONG ABOUT WHERE THE EXPOSURE WAS. It said an operator reading a submissions list would see a spoofable name. They would not: every delivery target - file, SMTP, webhook, and the separate form-smtp plugin - skips _-prefixed keys, so `_auth_user` never reached a stored record, an email or a webhook. It was DEAD. The live one was missed: the same unverified header went into the ACTOR COLUMN of lazysite/logs/audit.log, the shared trail that manager-api, dav, mcp, oauth and the users tool all write to with an identity they HAVE verified. A forged name there is a false record in the one artefact whose entire purpose is to say who did something - a worse place for it than the one originally described. Dropping only the dead field, which is what 'drop _auth_user' would have meant taken literally, would have looked like the fix and left the live one in place. THE FIX: the handler now reads NO identity from the request at all. A public form submission has no verified actor and is recorded as having none; the submitting address is still audited, because that is the fact that is actually known. Nothing is lost - there is no configuration under which this handler could have trusted the header, since auth_proxy_trusted is consulted by the PROCESSOR on the request the processor handles. The three candidate fixes below (verify the cookie here, extract session verification into a module, route this handler through the wrapper) are all still open as ways to give the handler a REAL identity, if one is ever wanted; none is needed to stop recording a false one. t/unit/forms/07 asserts the header is not read, that the audit entry carries no actor, that the address is still recorded, and that the delivery targets still skip _-prefixed keys - the property that made the dead field harmless."
---

# The finding

`plugins/form-handler.pl` does:

```perl
my $auth_user = $ENV{HTTP_X_REMOTE_USER} // '';
$form{_auth_user} = $auth_user if length $auth_user;
```

The processor strips those trust headers unless the auth wrapper vouched
(`LAZYSITE_AUTH_TRUSTED=1`) or the operator opted into a trusted proxy. **That
stripping never runs for this handler**, because the shipped templates front only
`lazysite-processor.pl` and `lazysite-manager-api.pl` with the wrapper, and
`/cgi-bin/` is otherwise a plain `ScriptAlias`.

So anyone posting to the form endpoint with `X-Remote-User: alice` produces a
stored submission attributed to alice.

# What it is not

It grants nothing. Every capability gate is on a surface that IS wrapped, and
the header reaching this handler buys no access anywhere. Nothing in the
platform currently treats `_auth_user` as authoritative.

# Where it actually was - a correction to this filing

This filing originally said an operator reading a **submissions list** would see
a spoofable name. That was wrong, and checking it is what found the real one.

::: widebox
`_auth_user` never reached a submissions list. Every delivery target - file,
SMTP, webhook, and the separate form-smtp plugin - skips `_`-prefixed keys, so
it was written into the request hash and then dropped by every consumer. It was
**dead**.
:::

The live path was the one this filing missed. The same unverified header went
into the **actor column of `lazysite/logs/audit.log`** - the shared trail that
manager-api, WebDAV, MCP, OAuth and the users tool all write to with an identity
they *have* verified. A forged name there is a false record in the one artefact
whose entire purpose is to say who did something, sitting indistinguishably
beside verified ones.

That is a worse place for it than the one originally described, and it means
**dropping only the dead field would have looked like the fix** while leaving
the live one untouched.

# Three fixes, none obviously right

Verify the cookie in the handler
: The `lazysite_auth` cookie is HMAC-signed and `lazysite-auth.pl` already
  validates it itself, for exactly this reason - it is not behind the wrapper
  either. But that logic lives in a **script, not a module**, so the handler
  cannot require it, and copying it makes a second copy of a security-critical
  verification. The house answer to a fact that must exist twice is a
  behaviour-comparing drift lint (t/lint/60 for the manifest pair) - viable, but
  it is a new copy of the auth spine.

Extract the session verification into a module
: Cleanest long term, and both callers use one implementation. It touches the
  auth spine, which is the part of this system with the least tolerance for a
  careless change.

Route the handler through the auth wrapper
: A front-end template change across four Apache and four nginx templates plus
  the front door. It also runs against SM286's direction - the front end decides
  less, not more - and an anonymous submission to a public contact form must
  keep working, so the wrapper would have to pass unauthenticated requests
  through unchanged.

# What was done

The handler reads **no identity from the request at all**. A public form
submission has no verified actor, so it is recorded as having none; the
submitting address is still audited, because that is the fact that is actually
known.

Nothing is lost. There is no configuration under which this handler could have
trusted the header: `auth_proxy_trusted` is consulted by the **processor**, on
the request the processor handles, and this script cannot tell a proxied
identity from an invented one.

The three fixes above remain open as ways to give this handler a **real**
identity, should one ever be wanted - for a form that should only accept
submissions from signed-in people, say. None of them is needed to stop recording
a false one, which is why that did not wait for the decision.
