---
title: "SM486: a feature-test page put itself in customers' sitemaps"
subtitle: "Four of nine live sites served it publicly, one under the client's own name and offered to search engines. The cleanup was not merely tedious - it was unreliable, and it failed silently"
brand: plain
standard-margins: true
status: shipped
status-note: "FROM AN OPERATOR COMPLAINT - 'every time we have to pick through and remove boilerplate' - which a field agent then MEASURED across nine delivered sites. Four served /lazysite-demo publicly; on the poultry-feed site it rendered as 'lazysite Feature Test - Marriage & Morris' and appeared in that site's public sitemap.xml, so it was OFFERED TO SEARCH ENGINES rather than merely left reachable. The page declared register: [llms.txt, sitemap.xml] and did exactly what it was told. THE MEASUREMENT CHANGED THE PROBLEM: the complaint was tedium, and the finding is that the cleanup is UNRELIABLE and fails SILENTLY - nothing on the site says the page is still there, and the one place advertising it is the sitemap, which nobody reads. Making cleanup easier is worth doing; making it unnecessary is worth more. TWO FIXES, AND ONLY ONE OF THEM IS THIS FILING: the demonstration page no longer registers itself anywhere, and t/lint/82 keeps it that way. THE SEPARABLE-FOLDER PROPOSAL IS NOT DONE, deliberately: starter/ is not one kind of thing, and a single 'delete me at handover' folder cannot hold it. search-results.md is addressed by the engine BY PATH - the search form posts to /search-results and search is switched on by the file EXISTING - so moving it into a folder labelled deletable would invite the deletion that turns site search silently off. Instead every starter page now declares starter_role: infrastructure, demonstration or content, which is the distinction an operator actually needs when they are deleting, and which a folder cannot express without moving files that must not move. THE FOLDER PROPOSAL REMAINS OPEN as the operator's own item; this filing removes the harm it was reaching for. FOUND BY THE LINT ITSELF: payment-members-demo.md, which I had not listed and which the check caught on its first run."
---

# Measured, not supposed

Nine live sites, asked for three starter pages over a plain public GET:

```datatable
columns: Site | /lazysite-demo
widths: 8.4cm | X
bold: 1
tone: medium
---
marriage-morris.thisisus.co.uk | **200**, and in the sitemap
dito.tech | **200**
odysseytimeship.com | **200**
community.dhcf.eu | **200**
the other five | 404
```

# Why it is worse than tedious

The page did not linger because somebody forgot once. It **advertised itself**:
`register: [llms.txt, sitemap.xml]`. So the one signal that would tell an
operator it was still there is the file nobody reads, and the audience that
does read it is search engines.

# What the folder proposal cannot do

`starter/` holds three different things, and only one of them is safe to
delete:

```datatable
columns: Kind | What happens if it is deleted
widths: 4.4cm | X
bold: 1
tone: medium
---
`infrastructure` | **a feature turns itself off, silently.** The search form posts to `/search-results`, and search is enabled by that file EXISTING
`demonstration` | nothing. This is what handover cleanup is for
`content` | the operator's own page, edited or replaced
```

A single folder marked *delete me at handover* would put the first kind on the
list. So the kinds are declared in the pages instead, where the engine's
path-addressing does not have to change and nothing has to move.

The operator's folder proposal stays open on its own merits. This removes the
harm it was reaching for.
