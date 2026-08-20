---
title: "SM416: the asset cache lifetime is the operator's dial"
subtitle: "On the lazysite front end every stylesheet, font and image revalidates on every page view - deliberate (SM387: protection must reach already-fetched assets), but the field sized it at ~6 engine round trips per view. asset_max_age lets a site trade a bounded staleness window for browser caching; the default trades nothing."
brand: plain
standard-margins: true
status: shipped
status-note: "SHIPPED 2026-08-20, decided by the release manager the same evening the field sized the cost (site agent filing, archived at inbox/archive/2026-08-20-asset-caching-is-front-end-dependent.md): the max-age becomes a SITE SETTING. Implementation respects why the default exists - SM387 chose pure revalidation so that protecting a path takes effect for visitors who already fetched it (the SM331 lesson one layer out), so the DEFAULT IS UNCHANGED (0 = revalidate always) and an operator who sets a value is choosing a bounded window knowingly, with the note on the setting saying exactly what the trade costs. ACL-governed assets are no-store ABSOLUTELY, whatever the dial - a sabotage that removed that guard was caught only after the test was fixed to make an AUTHORISED request, the anonymous version having measured the refusal path's no-store instead of the helper's (recorded in the test). One helper feeds both the 200 and 304 paths. The layouts briefing now names WHICH front end its caching advice applies to - the field's fourth suggested decision, verbatim: a layout author could not tell that the ten-year note did not apply to them. Allow-listed and validated in config-set; on the Config page with the trade spelled out in its note."
---

# The rule

The default is the safe trade and it is not a default by accident: SM387 chose
revalidation so protection reaches browser caches. `asset_max_age` (seconds)
is the operator saying "my assets may be up to N seconds stale, in exchange
for browser caching" - per site, visible on the Config page, never inherited.

ACL-governed assets are `no-store` whatever the dial says.

# Source of truth

`_static_cache_control` in the processor; t/unit/processor/43 (extended - the
SM387 test gains the dial's cases); the field filing in the inbox archive.
