---
id: SM710
title: The microphone is denied to every site, with no way for one to ask
raised: 2026-09-01
raised-by: site agent (familyhq.explore), via the dev inbox
area: security
status: candidate
---

# What happens

Every response carries `Permissions-Policy: ... microphone=() ...` from
`@DENIED_FEATURES` in `lib/Lazysite/SecurityHeaders.pm`, copied into
`lazysite-processor.pl` and pinned by `t/lint/55`. `microphone=()` is an EMPTY
allowlist: it denies the feature to every origin including `self`, so a page
cannot even prompt. The browser's own per-site permission is never consulted,
because the page was refused at the policy layer first.

familyhq's Hygge tab has a record button using in-browser `SpeechRecognition`
(no audio leaves the browser). On Chrome and Edge - the browsers that have the
API - it throws `not-allowed` for every user on the host.

# Correct the attribution, because it matters for who fixes it

The filing agent reported this as a front-proxy header, reasonably: the same
response carries `x-lazysite-front: hestia-proxy/acl`. **It is not the proxy.**
The engine emits it, on every response, from a hard-coded list. There is no
Hestia template to edit and nothing to ask of the front end - which is SM286's
rule anyway: the engine asks the proxy for nothing.

So this is ours, and the operator has no workaround available to them.

# The shape of an answer

The denial is a good default and should stay one. What is missing is any way for
a site that legitimately needs a feature to say so. `_csp_mode` is the precedent
sitting beside it: a site decision read from `lazysite.conf` and sanitised, where
an unrecognised value **fails safe** rather than silently disabling the header.

A `permissions_allow` key would follow the same shape - names checked against
`@DENIED_FEATURES`, anything unrecognised stays denied, a named feature emitting
`microphone=(self)`. Two places to change, one lint that catches drift.

**The constraint to decide first.** `_conf_value` reads
`$LAZYSITE_DIR/lazysite.conf`, which is per-INSTANCE, not per-domain. On a
multi-site instance the relaxation would apply to every domain on it. familyhq
is its own instance so it does not bite there, but per-domain granularity means
routing through `resolve_site_vars` and is a larger change.

Camera and geolocation would want the same shape eventually. Deliberately
absent from `@DENIED_FEATURES` already: autoplay, fullscreen and
picture-in-picture, on the reasoning that they are things a page's own content
might legitimately want.

# Also worth doing, and cheaper

Whatever is decided about the opt-in, the authoring and layouts briefings say
nothing about these features being hard-denied by the platform. An author can
ship a microphone feature that cannot work and get no warning until a user
reports it. Documenting the denied list, and how a site asks for an exception,
is worth more per hour than the mechanism.
