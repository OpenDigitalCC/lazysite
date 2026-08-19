---
title: "SM402: the form handler tags submissions with a header nobody verified"
subtitle: "form-handler.pl records _auth_user from HTTP_X_REMOTE_USER, but it is not behind the auth wrapper - so that header is whatever the client sent. The attribution on a stored submission can be set by the submitter."
brand: plain
standard-margins: true
status: candidate
status-note: "FOUND 2026-08-19 while scoping SM401's rate-limit exemption, which would have trusted the same header for a security decision and was built differently because of this. NOT EXPLOITED, and the impact is bounded: the header grants no access - every capability gate lives on surfaces that ARE wrapped - so this is a false ATTRIBUTION on stored data, not an escalation. But a submission that reads `_auth_user: alice` when alice did not send it is evidence of the wrong thing, and an operator reading a submissions list has no way to tell the difference. Filed rather than fixed because the fix is a design choice between three options with different blast radii, and none of them is obviously right - see below. Not urgent: it requires an operator who reads _auth_user as authoritative, and nothing in the platform currently does."
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

# Why it still matters

An operator reading a submissions list sees a name beside an entry and reads it
as who sent it. That is the only reason the field exists. A field that can be
set by the person it names is worse than an absent one, because an absent field
prompts a question and a wrong one answers it.

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

# Recommendation

Drop `_auth_user` until one of the above is done, or rename it to something that
does not read as verified. Recording an unverified claim under a name that
implies verification is the defect; not recording it costs nothing today,
because nothing consumes it.

That is a call for the release manager rather than a change to make quietly, so
it is filed rather than done.
