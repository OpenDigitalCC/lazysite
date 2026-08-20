---
title: "SM432: /docs/features is published in the sitemap and 404s"
subtitle: "A page and a directory share a name. The page serves, the leaf pages under the directory serve, and the canonical extensionless URL - the one the sitemap advertises - is shadowed by the directory and lands on a 404."
brand: plain
standard-margins: true
status: shipped
status-note: "RESOLVED 2026-08-20 by moving the page to starter/docs/features/index.md, on the release manager's instruction. The page was an INDEX of the directory shadowing it, and canonical_url_for maps foo/index.md to /foo - so the published URL /docs/features is unchanged, with no alias, no redirect chain, and no front-matter edit (the three tt_page_var scans are absolute and target subdirectories, so the index cannot list itself). CHOSEN OVER RENAME-PLUS-ALIAS FOR A REASON THE DEPLOY SUPPLIED RATHER THAN TASTE: when 0.10.19 reinstalled features.md onto edge mid-edit - the code-bucket overwrite predicted in the original filing, confirmed within the hour - the reinstated file came back shadowed by a directory that now has an index, so it was inert and the site kept working. Under rename-plus-alias the identical reinstall restores the 404, because the alias lives on a page the installer does not know about. The index route degrades safely against the one event guaranteed to recur on every upgrade. t/lint/67's exclusion list is now EMPTY and its guard fired for real: the lint refuses an exclusion for a collision that no longer exists, so removing the entry was part of this change rather than a follow-up. SEVERITY AMENDED 2026-08-20, from the field, and the amendment matters more than the fix: the original line below reads 'one failing URL across a 34-page sitemap', which UNDERSTATES IT. starter/lazysite/nav.conf line 9 ships 'All features | /docs/features' - a DEFAULT NAVIGATION ITEM, rendered in the site chrome on every page of every install. So the shipped state was a visibly broken menu link on a fresh site before anyone had authored anything, rather than one entry in a registry visitors never read. Verified in the tracked tree at starter/lazysite/nav.conf:9. Confirmed independently a third time on sites.lazysite.io - a fresh starter install on 0.10.19, on a host the reporter had never edited. The remedy is unchanged and the branch is right; what changes is how the record reads to a later reviewer, because 'one sitemap URL' invites a low priority and a broken default nav item does not. IT ALSO GIVES A BETTER ACCEPTANCE TEST than the sitemap one: follow the nav link on a fresh install and land on a page. ORIGINAL FILING FOLLOWS. FILED 2026-08-20 from the field, and IT SHIPS: starter/docs/features.md and starter/docs/features/ both exist in the tracked starter payload, so this is not an edge content mistake - every site that installs the docs inherits the collision. One failing URL across a 34-page sitemap; one collision under /docs (60 entries, 30 pages, 3 directories). WHAT WORKS AND WHAT DOES NOT: features.md serves 200 and renders correctly, and the leaf pages under features/ serve correctly; only the extensionless canonical URL fails, which is precisely the one sitemap.xml publishes. THE 301 COMES BACK AS charset=iso-8859-1, so the front end is issuing the redirect rather than the engine - which means the engine cannot see this happening and no engine-level test can catch it. HOW IT WAS FOUND, and this is the part worth keeping: the reporter wrote a sweep tool to make the check one command, ran it against their own filing, and it contradicted them - they had measured the 301 and ASSUMED its target, taking the version from the rendered error page. They corrected the promotion record before it was quoted. NOT CHANGED BY ANYONE: renaming either side moves a documentation URL, the standing aliasing rule would apply to whichever name loses, and doing that during a promotion cut is a release decision rather than a fix. DECISION HELD."
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
`/docs/features` (canonical, in sitemap.xml) | **was: 301 to `/docs/features/`, which 404s** - now serves the index
`/docs/features` (**default nav item**, `nav.conf:9`) | same URL, so **the site chrome carried a broken link on every page**
```

::: widebox
The failing URL is the one the sitemap advertises **and the one the shipped
navigation points at**. `starter/lazysite/nav.conf` line 9 reads
`All features | /docs/features`, so a fresh install rendered a broken menu
item in its chrome on every page before anybody had authored a thing. That is
the severity to read this filing at - not one row in a registry visitors never
open.

It is also the acceptance test worth keeping: install fresh, follow the nav
link, land on a page.
:::

# Why no test caught it

The redirect carries `charset=iso-8859-1`, so it is the front end answering,
not the engine. Nothing at the processor level can see a URL the front end
resolves before the engine is consulted - the same blind spot as the SM283
family, and the reason the whole outside-in probe exists.

# The decision

*Taken 2026-08-20: the index move. See the status note.*

Renaming either side moves a published documentation URL. The standing rule
is that a retired URL gets an alias on its successor, so whichever name loses
needs one - and doing that during a promotion is a release decision, not a
fix somebody makes on the way past.

Worth checking as part of it: whether any other page/directory pair in the
shipped starter docs collides the same way, since this one shipped without
anybody noticing.
