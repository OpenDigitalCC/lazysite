---
id: SM1350
title: "SM1350: many small sites, kept by people who are not technical"
subtitle: "Hundreds to a few thousand one-to-five-page sites, each owned by a small business. Created one at a time from a brief, run by a service team, and updated by owners from a phone. These are the engine changes that make this lazy again. Specifics of any one market belong in an app, not the engine."
brand: plain
standard-margins: true
status: candidate
raised: 2026-11-06
raised-by: "release manager, discussion of a prospective order (2026-11-06)"
area: platform
status-note: "Filed 2026-11-06 as the umbrella for SM1351-SM1362. Not scheduled; ruling questions below."
---

# The shape

- **Sites:** 500 to 2500 small sites. Each is mostly one page, a few have two to five, all with basic imagery. They draw on about 50 layouts and 100 themes.
- **Created serially:** one site at a time, each from a client brief, and never as a bulk import.
- **Pre-sales:** sites start on a subdomain of one wildcard-certificate domain. They run in a container behind a dedicated Caddy or nginx, not on Hestia.
- **On purchase:** a site may move to its own domain. That may also mean moving to Hestia, which brings mailboxes and a more managed service.
- **Service team:** many clients want a managed service, so one service team works across every site.
- **Owners:** the owners are not technical. They update rarely, mostly from a phone: switching what is available, changing hours, sending a photo of a printed or chalked list.
- **Shared and separate:** every site shares one sending account for its notification email, and each has its own forms.
- **Search:** search engine and AI search data matters to every site.

# Decision taken in discussion: one instance per site

Each site is its own small instance. They share one read-only copy of the engine and one layout catalogue.

- **Isolation comes free.** One client can never reach another, so T-44 is no longer a blocker.
- **The domain list never grows** beyond a site's own domains.
- **Moving a site** means moving its folder.

The costs: many small upgrades, which need a script; and the service team needs one sign-in that works across every instance (SM1351).

# The engine pieces

| SM | Piece | Depends on |
|---|---|---|
| SM1351 | Sign in through an outside identity provider, with groups | ruling 70's identity hook |
| SM1352 | Passkeys | - |
| SM1353 | More than one manager interface, chosen by group | - |
| SM1354 | Copy a page, change the copy, publish it over the original | content history |
| SM1355 | Wizards that build and switch rows of a data table | data tables |
| SM1356 | Schedules: weekly hours, exceptions, dated items | data tables |
| SM1357 | Structured data for search engines and AI search, from data and schedules | SM1355, SM1356 |
| SM1358 | The site as an installable app on a phone | SM1352 |
| SM1359 | Photo updates: a transient intake, read by a connected agent, proposed as a copy | SM1354, SM1358 |
| SM1360 | The client room: one thread between a site's owner and its agent | SM1353 |
| SM1361 | Instance per site: shared engine and catalogue, create from a brief, move to a domain, paging | - |
| SM1362 | A bare form saves to file storage and notifies the owner | sites evidence (inbox request, 2026-11-06) |

# Order

1. **SM1354 and SM1355:** they rest on what already exists.
2. **SM1361, SM1351 and SM1352:** the platform the service team needs.
3. **SM1356 and SM1357.**
4. **SM1358 and SM1359.**
5. **SM1353 and SM1360:** the simple manager's contents become clear as the pieces above land.

# Principle

Each piece is generic, aligned with core lazysite, and useful to any site. What one market needs lives in that market's app: its layouts, its wizard definitions, its search data mapping and its photo-matching instructions. The engine never names a market or a client.
