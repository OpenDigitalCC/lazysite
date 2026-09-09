---
id: SM799
title: "SM799: a token client can author a form but cannot bind one"
subtitle: "From sites.lazysite.io on 0.12.1, with manage_forms held: writing the page, declaring the form and putting the block in the body all work over the control API and WebDAV. Binding it to a handler - the step that makes it deliver - has no route a token client may call, and describe-capabilities advertises the four actions that would do it while actions-list does not list them."
brand: plain
standard-margins: true
status: superseded
superseded-by: SM779
status-note: "ALREADY ANSWERED, verified 2026-09-09 and not rebuilt. The report is against 0.12.1; SM779 shipped in 0.13.8 and does exactly what this asks. All four actions - handler-list, handler-save, form-targets-read, form-targets-save - are declared caps => undef (cookie-only), none is token-callable, and the capability map now publishes cookie_only: true for each. So the two documents no longer disagree: actions-list omits them because the channel cannot serve them, and describe-capabilities says WHY rather than listing a door that does not open. The design question underneath was answered the same way SM579 phase 2 answered it for connectors: deciding where submissions go is an operator act, so cookie-only is correct and the map saying so is the whole fix."
---

# The gap

Authoring a native form is entirely reachable: write the page, declare
`form: <name>` in the front matter, put a `::: form` block in the body, PUT it.
Binding that form to a sysop-vetted handler is not.

`form-targets-save`, `form-targets-read`, `handler-save` and `handler-list` are
advertised by `describe-capabilities` among 141 actions and are absent from the
77 that `actions-list` says this account can call. So the map names a door the
channel does not open - which is the shape SM779 addressed for the cookie-only
actions, and this is the same complaint arriving about a different set.

# Verified closed, 2026-09-09

Checked before building anything, because the report is against 0.12.1 and
SM779 landed in 0.13.8:

    handler-list         token-callable=no    cookie_only=TRUE
    handler-save         token-callable=no    cookie_only=TRUE
    form-targets-read    token-callable=no    cookie_only=TRUE
    form-targets-save    token-callable=no    cookie_only=TRUE
    form-delete          token-callable=YES

The map no longer advertises a door the channel will not open; it names the
channel. That is precisely what the filing asked for, and SM779 did it for the
general case rather than for these four.

# The question behind it

Binding a form to a handler decides **where submissions go**. That is the same
class of authority as writing a connector, and SM579 phase 2 has just answered
it for connectors in the opposite direction: writing a destination is an
operator act at a human surface, and an agent may only *use* what an operator
configured.

If that answer is right for connectors it is probably right here, and then the
defect is not the missing route but the **map advertising it**: a token client
should be told these are cookie-only, by name, the way SM779's `cookie_only`
flag says it. If the answer is different - because a handler is sysop-vetted
already, so binding to one confers nothing new - then the route should exist.

Either way the two surfaces should stop disagreeing.

# Provenance

`inbox/2026-09-08-no-control-api-route-to-bind-a-form.md`, reported from
`sites.lazysite.io` on 0.12.1. The behaviour is not verified against 0.13.8
here; the map-versus-channel disagreement is the part to check first, because
SM779 changed exactly that surface after 0.12.1.
