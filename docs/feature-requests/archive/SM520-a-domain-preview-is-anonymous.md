---
title: "SM520: a domain preview is anonymous"
subtitle: "preview_public stripped the operator's session cookie and Authorization header before rendering; domain_preview stripped only the proxy-identity variables. The domain check therefore rendered as the operator and showed a gated section as visible."
brand: plain
standard-margins: true
status: shipped
status-note: "FOUND 2026-08-25 by the Themes/Layouts/Domains/Plugins structural review, proven by probe tmp/tl-probe-preview-cookie.pl: with a stub processor echoing its environment, preview_public showed HTTP_COOKIE=<stripped> while domain_preview showed HTTP_COOKIE=lzs_session=SECRET and HTTP_AUTHORIZATION=Bearer SECRET - and the processor hands HTTP_COOKIE to its front route and cookie reader, so forwarding it IS logging in. SHIPPED 0.10.32 (the beta build) as one helper, Domains::_anonymous_env(), called by both previews so the two strip lists cannot drift again. t/unit/manager/101 drives both through the stub, asserts the html carries neither the session nor the gated body, and pins the shared call. The other credential readers under lib/ (Auth::Session reads HTTP_COOKIE; the manager API reads HTTP_AUTHORIZATION) are the authentication path, not subprocess renders, and are unchanged."
---

# The rule

*A preview that claims the visitor's view renders as nobody.* Anything in
the environment that could tell the processor who is asking has to go
before the processor is shelled - and the list of what to remove lives in
one place, because two hand-written copies of it have already disagreed.

# What changed

- `_anonymous_env()` strips `HTTP_X_REMOTE_*`, `LAZYSITE_AUTH_*`,
  `HTTP_COOKIE` and `HTTP_AUTHORIZATION` from the localised `%ENV`.
- `preview_public` and `domain_preview` both call it; neither carries its
  own list.
