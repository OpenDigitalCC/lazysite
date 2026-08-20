---
title: "SM441: page preview renders a domain's page in the default theme"
subtitle: "The Files preview shells the processor without a Host, so SM151's per-Host routing never fires. The page renders with the base layout, theme and nav - whoever it actually belongs to."
brand: plain
standard-margins: true
status: shipped
status-note: "SHIPPED (PENDING). Both page-scope previews now render under the owning domain's Host, resolved by Domains::host_for_path - longest content root wins, containment is boundary-safe, and a path no content root contains returns empty so the primary keeps today's correct behaviour. THE AMBIGUOUS CASE IS NOT PRETENDED SOLVED: two domains declaring one content_root have no fact deciding between them, so the function reports the tie count and picks deterministically by sorted host - strictly better than the primary-always behaviour it replaces, and a host selector on the preview remains the real answer. ORIGINAL FILING FOLLOWS. REPORTED 2026-08-20 by the release manager: 'files app doesn't know about the domain theme, so preview renders content in the default theme'. CONFIRMED IN THE SOURCE, and the source documents the contrast itself. action_preview sets REDIRECT_URL, DOCUMENT_ROOT and LAZYSITE_NOCACHE and shells the processor - and never sets HTTP_HOST. The comment on the sub immediately BELOW it says domain_preview shells the processor 'exactly like the dev server / action_preview, but with HTTP_HOST set (SM151 per-Host routing picks the domain's content_root + theme/layout/nav overrides)'. So the difference was understood and applied at DOMAIN scope only; page scope never got it. WHAT ACTUALLY HAPPENS: `local %ENV` keeps the manager request's own HTTP_HOST, so the preview renders under whatever host the OPERATOR is browsing the manager on - normally the default. The processor's $declared{$req_host} lookup misses the page's owning domain, no alias overlay applies, and the base conf supplies layout, theme and nav. The CONTENT is right (the docroot-relative path resolves under the default host, whose content root is the docroot) and the PRESENTATION is the wrong site's. BOTH PAGE-SCOPE PREVIEWS HAVE IT: preview_public (SM282, 'what a PUBLIC visitor gets for one path') sets DOCUMENT_ROOT, REDIRECT_URL, REQUEST_METHOD, QUERY_STRING and LAZYSITE_NOCACHE, and no HTTP_HOST either. Fixing the Files preview alone would leave the as-a-visitor preview still wrong, which is the worse of the two to leave - it is the one that claims to show what the public sees. REMEDY: derive the owning domain from the file's path by matching it against each domain's content_root, and set HTTP_HOST to that domain's host before shelling. domains_list already returns content_root per host, so the lookup is a prefix match. Two things to decide rather than assume: what to do when no content root contains the path (the primary owns it - current behaviour is then correct), and what to do when more than one domain declares the same content_root (ambiguous; a host selector on the preview is one answer). EVIDENCE: read from the source, not exercised. THE PATTERN THIS IS THE THIRD OF: see the closing section - SM436, SM440 and this are one shape, and it is worth reading them together."
---

# What the two previews set

```datatable
columns: Preview | Sets HTTP_HOST | Result for a domain's page
widths: 6cm | 3cm | X
bold: 1
tone: medium
---
`domain_preview` (SM238, domain scope) | **yes** | correct - overrides apply
`action_preview` (Files / editor) | no | **base layout, theme and nav**
`preview_public` (SM282, "as a visitor") | no | **base layout, theme and nav**
```

::: widebox
The content is right and the presentation is another site's. That is the
awkward failure: it looks like a working preview of a page that has been given
the wrong theme, rather than like a preview that is not being told which site
it is previewing.
:::

# The difference was known

`action_preview`:

```perl
local $ENV{LAZYSITE_NOCACHE} = '1';
local $ENV{REDIRECT_URL}     = $uri;
local $ENV{DOCUMENT_ROOT}    = $DOCROOT;
```

The comment on the very next sub, describing `domain_preview`:

> Shells the processor exactly like the dev server / `action_preview`, but with
> `HTTP_HOST` set (SM151 per-Host routing picks the domain's `content_root` +
> theme/layout/nav overrides)

So this is not an oversight about how routing works. It is the fix applied at
one scope and not the other.

# What it renders instead

`local %ENV` keeps the manager request's `HTTP_HOST`, so the preview renders
under the host the OPERATOR is browsing the manager on. On a normal setup that
is the default host, so `$declared{$req_host}` misses the page's owning domain,
no overlay applies, and the base conf supplies the presentation.

An operator who happened to open the manager on the domain's OWN host would see
a correct preview - which makes this intermittent in exactly the way that wastes
an afternoon.

# Remedy

Derive the owning domain from the path by matching it against each domain's
`content_root`, and set `HTTP_HOST` before shelling. `domains_list` already
returns `content_root` per host, so it is a prefix match.

Two things to decide rather than assume:

- **No content root contains the path.** The primary owns it, and today's
  behaviour is then already correct.
- **Two domains declare the same content_root.** Genuinely ambiguous. A host
  selector on the preview is one answer; picking the first is not.

Fix both previews together. `preview_public` is the worse one to leave, because
it is the one that claims to show what the public sees.

# The third of a shape

Three findings today have one cause in different clothes: **the manager reasons
in docroot terms while the site is served in per-Host terms.**

```datatable
columns: Filing | Where the assumption sits
widths: 4cm | X
bold: 1
tone: medium
---
SM436 | `domain_preview` feeds the STORED key back as the Host, so it validates the config against itself
SM440 | aliases derive a docroot-relative URL, and the map is instance-wide
SM441 | page previews send no Host at all
```

Each was found separately, by different symptoms, by different people. Worth
reading together before any of them is fixed in isolation - a fix that teaches
one surface about hosts while the neighbours keep assuming a single site just
moves the seam.
