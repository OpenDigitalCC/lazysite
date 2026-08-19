---
title: "SM387: engine-served statics revalidate, and that is a choice"
subtitle: "On the SM283 proxy template every static comes back through the engine and the front end's ten-year cache is gone. Reported as a possible regression. It stays - a long cache here would put SM331 in the visitor's browser, where nothing can reach it."
brand: plain
standard-margins: true
status: shipped
status-note: "DOCUMENTED 2026-08-19, behaviour unchanged and deliberately so. Measured in the field by the site agent after the proxy template went on edge: /lazysite-assets/..., /favicon.ico and /assets/lazysite-chrome.js all moved from max-age=315360000 to no-cache, must-revalidate. They were right that it should be CHOSEN rather than found, and right to raise it; the choice is to keep revalidation, because a long cache would make protecting a path ineffective for anyone who had already fetched the file. The reasoning now sits at the decision, the docs no longer describe the stock template as though it were the rule, and t/unit/processor/43 pins it."
---

# What was measured

After the SM283 proxy template went on edge:

```datatable
columns: Asset | Before | After
widths: 5.6cm | 3.4cm | X
bold: 1
tone: medium
---
`/lazysite-assets/lumen/lumen/main.css` | `max-age=315360000` | `no-cache, must-revalidate`
`/favicon.ico` | `max-age=315360000` | `no-cache, must-revalidate`
`/assets/lazysite-chrome.js` | `max-age=315360000` | `no-cache, must-revalidate`
---
```

Measured without a query string, so not a cache-buster artefact. Every
asset revalidates on every request, on contended shared hosting.

# Why it stays

A static served by the engine is **public right now and can be protected
at any moment** - that is the whole point of SM223: protection is a
content action, with no vhost regeneration and no reload.

::: widebox
**A ten-year copy in a visitor's browser outlives the protection.** They
would go on reading a file for years after the operator gated the
folder, in their own cache, where nothing the engine or the front end
does can reach them. [[SM331]] was exactly this in the front end's
descriptor cache and took three filings to understand; the browser is
the same defect one layer further out, and further out of reach.
:::

`must-revalidate` is what makes protecting a path take effect for
someone who has already fetched the file.

# So the ten-year cache belongs to the fast path

It is a property of the **front-end fast path** - a site with no ACL
store, where nothing can become protected without an operator noticing -
and not of lazysite. Guidance describing a ten-year cache with `?v=`
busting is describing the stock template, and now says so.

# The cost, stated rather than hidden

Routing statics through the engine is what makes the gating work, and
SM293 step 5 already recorded that one rule costs a process per request.
This is the same trade in the cache: correctness of protection, paid for
in revalidation. An operator who wants the long cache back can have it,
by not putting the site on the ACL-aware template - which is the same
choice, stated the other way round.

# Verification

- An engine-served public static carries `must-revalidate` and no
  multi-year `max-age`.
- The fixture asserts it really served the stylesheet first, since a
  404 would carry different caching entirely.
- The reasoning is asserted to be present at the decision, because a
  choice with no stated reason gets re-litigated or "fixed".

# Related

[[SM331]] (the same defect one layer in), [[SM223]] (protection as a
content action, which is what makes the long cache unsafe), [[SM283]]
(the template that routes statics here), [[SM342]] (the performance
budget this spends).
