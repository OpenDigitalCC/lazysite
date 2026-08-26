---
title: "SM270: a control-panel rebuild takes a site's writability away, and nothing noticed until a save failed"
subtitle: "Fixed by ordering once, recurred three releases later, and recurred again across 26 sites after the 0.11.1 rollout"
brand: plain
standard-margins: true
status: shipped
status-note: "SHIPPED in 0.11.2 (2026-08-26) as a SAFETY NET plus the CURE WRITTEN DOWN - and those are different things, which is why this kept coming back. THE MECHANISM: Hestia's v-rebuild-web-domain re-applies its own docroot permissions, 2751 - setgid, NO group write - and the lazysite deploy's permission sweep is what repairs that. SM270 first fixed the ORDERING (rebuild before deploy, not after). It recurred because a rebuild driven through the CONTROL PANEL's own path never reaches that script at all: an SSL renewal, an alias change or a panel upgrade re-applies 2751 and no lazysite code runs. The end-of-run repair added next helps for the same reason and with the same limit - both only help when LAZYSITE RUNS. A stable-channel site that takes no deploy for a month is unwritable for a month, which is how 26 sites arrived at the 0.11.1 rollout needing repair. THE SAFETY NET: the manager now says so on its next page load instead of at the next failed save - the changelog's own description of the symptom was 'nothing notices until the manager fails to save', and this is that notice arriving early. Ownership and mode arithmetic rather than -w, which answers for the real uid while the question is about another identity; manager pages only, so a public visitor pays nothing and learns nothing; and the banner names the affected directories, the usual cause (so it is not read as a lazysite fault) and the one documented repair. THE CURE, which is the part nobody had written down: the permission fight exists ONLY under the no-suexec CGI, where the engine runs as www-data and therefore needs the site group-writable - exactly the bit Hestia strips. A site on the SM142 per-site FastCGI pool runs as its OWN user, so owner-write suffices, 2751 is harmless, and v-rebuild-web-domain cannot break it however often it runs. That was true and unstated for as long as this defect has existed. A site that keeps coming back with permission drift is telling you it should be on a pool. NOT CLAIMED: this does not prevent the drift on a shared-CGI site, and no engine change can - the panel owns those permissions. What changes is the time between breaking and knowing, from a month to a page load."
---

# Why fixing it twice did not fix it

| Fix | Helps when | Blind to |
|---|---|---|
| Order the rebuild before the deploy | `lazysite` runs | panel-driven rebuilds |
| Repair at the end of every run | `lazysite` runs | panel-driven rebuilds |
| **Say so on the next manager page** | always | nothing - but it only *reports* |
| **Run as the site user (SM142 pool)** | always | nothing - the cure |

The first two share one assumption, and it is the wrong one: that lazysite is
present when the damage happens. It is not. The panel does it.

# The two answers, for two kinds of site

**On the shared `www-data` CGI:** the banner tells you, `lazysite repair
--domain <site>` fixes it, and it will happen again on the next rebuild.

**On a per-site pool:** it cannot happen. The engine runs as the owner and
`2751` is a perfectly good mode.
