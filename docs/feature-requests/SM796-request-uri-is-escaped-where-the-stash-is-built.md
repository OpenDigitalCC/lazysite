---
id: SM796
title: "SM796: request_uri is escaped where the stash is built, like everything beside it"
subtitle: "Security review, 0.13.8, VERIFIED: every client-influenced value enters the render stash through _esc_html at one point - the SM709 invariant - except request_uri, which sits raw between two escaped neighbours and is interpolated into an href by the shipped 402 and 403 pages. Live reflection needs a front end that both omits REDIRECT_URL and passes breakout characters undecoded, which the shipped stacks do not; the invariant is broken either way."
brand: plain
standard-margins: true
status: shipped
status-note: "BUILT 2026-09-08 on claude/secrev-wild-request-path. request_uri goes through _esc_html at the stash entry point, so the invariant holds for every field again."
---

# The finding

The render path escapes author- and client-influenced values at the single
point where they enter the Template Toolkit stash, so that a layout which
interpolates without `| html` is still safe. That is the SM709 invariant, and
it is why the layouts do not carry filters.

`request_uri` enters raw:

    page_author       => _esc_html( $meta->{author} ),
    page_modified     => $meta->{page_modified} || '',
    request_uri       => $ENV{REDIRECT_URL} || $ENV{REQUEST_URI} || '',

one line below an `_esc_html` and in a block full of them. The shipped `402.md`
and `403.md` interpolate it into an `href`.

**The severity is honest and the review says so**: reflection is only live under
a front end that both omits `REDIRECT_URL` and hands `REQUEST_URI` on with
breakout characters decoded. The shipped Apache/Hestia stack and a standard
nginx do neither. So this is not a live hole on a shipped deployment - it is a
value outside an invariant the rest of the file keeps, in a field that reaches
an `href`, and the cost of putting it back inside is one function call.

That is the whole argument for fixing it now rather than filing it: an
invariant with one exception is not an invariant, and the next person to read
this block cannot tell that the exception was considered.

# What was built

`request_uri` goes through `_esc_html` at the stash entry point, like its
neighbours.

# Provenance

`inbox/2026-09-08-request-uri-unescaped-in-render-stash.md`. Accepted; the raw
assignment and its escaped neighbours were read here.
