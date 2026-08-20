---
title: "SM436: a domain can be registered under a name no request can ever carry"
subtitle: "alias_hosts accepts a single-label name like `dhcf`. The processor matches the full Host header with eq, so the alias never fires - and the visitor silently gets the PRIMARY site instead of the one that was configured."
brand: plain
standard-margins: true
status: candidate
status-note: "FILED 2026-08-20 from the operator's own staging instance, and the reported symptom was the OPPOSITE of the fault. The report was that the domain check looks up 'dhcf' rather than the full name and must be checking the wrong thing, since https://dhcf.sites.lazysite.io serves. THE CHECK IS CORRECT AND THE SITE IS NOT SERVING. That URL returns 200, and what it returns is the PRIMARY staging site - <title>Lazysite staging</title>, theme assets under lazysite-assets/atelier/ - not the DHCF site, which is configured with layout dhcf, theme dhcf-r2 and content_root sites/dhcf. Verified by fetching it. The content root exists and is populated, so nothing is lost; it is simply not reachable. THE MECHANISM: the domain is registered with host 'dhcf' and site_url https://dhcf.sites.lazysite.io. Wildcard DNS lands the request on the instance carrying Host: dhcf.sites.lazysite.io. lazysite-processor.pl builds %declared from alias_hosts and tests $declared{$req_host} where $req_host is the full sanitised Host - so 'dhcf' never matches, no alias overlay is applied, and the request falls through to the base conf, which is the primary. _valid_host in Manager/Domains.pm requires only that each dot-separated label be well formed, so a single label passes and domain_add accepts it. THREE DEFECTS, one data error: (1) a host with no dot cannot appear as a public Host header on a public instance and should be refused, or at minimum warned about, at domain_add; (2) an alias host that disagrees with the hostname in its OWN site_url is self-evidently wrong and nothing notices - that comparison is free and would have caught this at registration; (3) the failure is SILENT and lands in the SM248 class the code already names - the visitor is told whose site this is, incorrectly - except SM248 was about a favicon and this is the whole site. THE CHECK'S WORDING IS THE ONLY FAIR COMPLAINT: 'the host name does not resolve yet - add the DNS record' is true but misdirects, because the DNS is fine and the registered name is not a hostname. It sent the operator to their DNS provider to look for a fault that is in the conf. REMEDY for the instance is to re-register under the full name; remedy for the engine is items 1-3, held for decision."
---

# What was configured, and what a visitor gets

```datatable
columns: Thing | Value
widths: 6cm | X
bold: 1
tone: medium
---
Registered `host` | `dhcf` - **matched against the full Host header, so never**
`site_url` on the same row | `https://dhcf.sites.lazysite.io`
Intended appearance | layout `dhcf`, theme `dhcf-r2`, content root `sites/dhcf`
**Actually served there** | **the primary: "Lazysite staging", theme `atelier`**
```

::: widebox
The URL answers 200, which is why it reads as working. It is answering with a
different organisation's site. Nothing in the manager reports this, and the one
surface that DID detect it - the domain check - was read as the thing at fault.
:::

# Why it is silent

`lazysite-processor.pl` builds `%declared` from `alias_hosts` and applies the
overlay only when `$declared{$req_host}` is true, with `$req_host` the full
sanitised `Host`. A non-matching alias is indistinguishable from no alias at
all: the base conf is used, which is the documented and correct behaviour for
an undeclared host. There is no state in which the engine believes it is
serving `dhcf`, so there is nothing for it to report as wrong.

That is the right design for an unknown host arriving from outside. It is the
wrong outcome for a host the operator has REGISTERED, because registration is
the operator saying "I expect this to serve".

# The cheap check

The row already contains both halves. `site_url` on this domain is
`https://dhcf.sites.lazysite.io`; the registered host is `dhcf`. Comparing the
hostname in `site_url` against the alias host costs one regex and would have
refused the registration at the point the operator made it, when the fix was
one field rather than a live site quietly serving the wrong content.

# Not a DNS fault

Worth stating because the check's own wording sends the operator the wrong
way. `dhcf.sites.lazysite.io` resolves and terminates TLS correctly. The
string `dhcf` does not resolve because it is not a host name, and asking DNS
about it is the check faithfully doing what it was told. The message should
distinguish "this name has no DNS record" from "this name cannot have one".
