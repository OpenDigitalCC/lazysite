---
title: "SM253 - The 404 path ignores the domain's content root and emits no security headers"
subtitle: "A secondary domain serves the primary's 404 page, and every 404 response goes out without the baseline headers every other response carries."
brand: plain
status: shipped
status-note: "IMPLEMENTED in the 0.10.4 edge line (2026-08-09, commit d0bf6a9). Reported in a docs-audit note of 2026-07-26 that was never actioned; found and verified 2026-08-08. Two independent defects on one code path, both small. The content-root half is another SM151 edge - the FOURTH found on this family - and _system_page_md already takes the content root it is never given."
---

# SM253 - the 404 path skips the content root and the headers

Two defects share one short function, `not_found` in `lazysite-processor.pl`.

## 1. A secondary domain serves the primary's 404

`_system_page_md` resolves a system page through three tiers - the domain's
content root, then the docroot, then the shipped default:

```perl
sub _system_page_md {
    my ( $base, $croot ) = @_;
    $croot = $DOCROOT unless defined $croot && length $croot;
    for my $cand ( "$croot/$base.md", "$DOCROOT/$base.md",
        "$LAZYSITE_DIR/templates/system/$base.md" ) { ... }
}
```

`not_found` calls it with no content root:

```perl
my $md_path = _system_page_md('404') // "$DOCROOT/404.md";
```

So `$croot` falls back to `$DOCROOT` and the first tier collapses into the
second. A domain with its own `404.md` under its content root never serves it;
a visitor who mistypes a URL on a secondary domain gets the primary site's 404,
with the primary's branding and navigation.

The mechanism already exists - the function takes the parameter. Only the call
site omits it. The `$html_path` beside it is likewise hard-coded to
`"$DOCROOT/404.html"`, so the cache slot needs the same treatment.

This is the fourth SM151 edge in this family, after SM241 (the asset mirror),
SM242 (the documentation) and SM248 (docroot-root statics). That count is now the
argument for taking multi-domain as one pass rather than four.

## 2. A 404 carries none of the baseline headers

Every normal response goes through `output_page`, which emits
`X-Content-Type-Options: nosniff` and the rest of the baseline set. `not_found`
prints its own status and content type directly and emits none of them.

So the one response type most likely to be reached by a scanner, a crawler or a
mistyped URL is also the only one served without the protections every other
response gets. It also skips `$ACCESS_REC{b}`, so the analytics record carries no
byte count for a 404.

Routing the 404 body through `output_page` is the obvious fix, with the status
line overridden - `output_page` currently hard-codes `Status: 200 OK`, so it
needs to take a status, which is a small change with several callers to check.

## Verification

- A domain with its own `404.md` under its content root serves that page; one
  without still inherits the docroot's, then the shipped default.
- The 404 cache slot is per-domain, so one domain's rendered 404 is never served
  to another.
- A 404 response carries the same baseline security headers as a 200.
- The analytics record for a 404 carries a byte count.
- `output_page`'s existing callers are unaffected by the status parameter.

## Not in scope

- The other system pages (402, login). Worth checking for the same call-site
  omission, but they are a separate change with their own resolution rules.
- Adding CSP or HSTS, which are deliberately vhost concerns.
