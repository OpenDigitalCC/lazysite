---
title: "SM432: /docs/features is published in the sitemap and 404s"
subtitle: "A page and a directory share a name. The page serves, the leaf pages under the directory serve, and the canonical extensionless URL - the one the sitemap advertises - is shadowed by the directory and lands on a 404."
brand: plain
standard-margins: true
status: candidate
status-note: "FILED 2026-08-20 from the field, and IT SHIPS: starter/docs/features.md and starter/docs/features/ both exist in the tracked starter payload, so this is not an edge content mistake - every site that installs the docs inherits the collision. One failing URL across a 34-page sitemap; one collision under /docs (60 entries, 30 pages, 3 directories). WHAT WORKS AND WHAT DOES NOT: features.md serves 200 and renders correctly, and the leaf pages under features/ serve correctly; only the extensionless canonical URL fails, which is precisely the one sitemap.xml publishes. THE 301 COMES BACK AS charset=iso-8859-1, so the front end is issuing the redirect rather than the engine - which means the engine cannot see this happening and no engine-level test can catch it. HOW IT WAS FOUND, and this is the part worth keeping: the reporter wrote a sweep tool to make the check one command, ran it against their own filing, and it contradicted them - they had measured the 301 and ASSUMED its target, taking the version from the rendered error page. They corrected the promotion record before it was quoted. NOT CHANGED BY ANYONE: renaming either side moves a documentation URL, the standing aliasing rule would apply to whichever name loses, and doing that during a promotion cut is a release decision rather than a fix. DECISION HELD."
---

# The shape

```datatable
columns: URL | Result
widths: 6cm | X
bold: 1
tone: medium
---
`/docs/features.md` (source) | serves, renders correctly
`/docs/features/authoring/...` (leaves) | serve correctly
`/docs/features` (canonical, in sitemap.xml) | **301 to `/docs/features/`, which 404s**
```

::: widebox
The only URL that fails is the only one the sitemap advertises. A visitor
following the site's own published index of itself is the one person who
meets it.
:::

# Why no test caught it

The redirect carries `charset=iso-8859-1`, so it is the front end answering,
not the engine. Nothing at the processor level can see a URL the front end
resolves before the engine is consulted - the same blind spot as the SM283
family, and the reason the whole outside-in probe exists.

# The decision

Renaming either side moves a published documentation URL. The standing rule
is that a retired URL gets an alias on its successor, so whichever name loses
needs one - and doing that during a promotion is a release decision, not a
fix somebody makes on the way past.

Worth checking as part of it: whether any other page/directory pair in the
shipped starter docs collides the same way, since this one shipped without
anybody noticing.
