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

# A shape for the opt-in, and a second driver (site agent, 2026-09-27)

A proposal filed to the dev inbox asks for the same mechanism for a different
feature, which settles that this is a general question rather than one about the
microphone. The driver is a capture form: photographing a business card into a
lead form at an expo, with the image handed on to be read. `camera=()` refuses
`getUserMedia` on every page of every site, so an in-page capture widget with a
live preview and a shutter cannot be built at all. The hand-off half of that
proposal is [[SM905]].

**The proposed shape is two keys, both required, and it answers the constraint
this filing raised.**

- An instance key naming which features an admin will permit **at all**, say
  `permissions_policy_allow: camera`. Empty by default, so every existing site
  is unchanged.
- A page declaring in its front matter that it **uses** one, say
  `device: camera`. The header is relaxed on that response only.

Per-feature names, never a free-text header string, or the engine loses the
ability to reason about what it is sending. An unrecognised or unpermitted value
denies, which is the direction `_csp_mode` already fails in and the lesson SM356
recorded about a typo granting rather than refusing. The switch is a change of
security posture, so it belongs in the audit trail the way `audit-trail-set`
does.

**Why two keys rather than one.** Permissions-Policy is a per-response header, so
site-wide relaxation to serve a single capture page is broader than the need and
does not have to be. That also dissolves the per-instance versus per-domain
problem raised above: the instance key is only a ceiling, and the page
declaration is what actually relaxes anything, so a multi-site instance does not
hand the camera to every domain on it. Routing through `resolve_site_vars` stops
being necessary for the common case.

**If only one half is built, build the page half.** An instance-wide `camera=*`
is the outcome worth avoiding, and it is what a single switch would produce.
