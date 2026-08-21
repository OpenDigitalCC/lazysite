---
title: "SM436: a domain can be registered under a name no request can ever carry"
subtitle: "alias_hosts accepts a single-label name like `dhcf`. The processor matches the full Host header with eq, so the alias never fires - and the visitor silently gets the PRIMARY site instead of the one that was configured."
brand: plain
standard-margins: true
status: shipped
status-note: "SHIPPED (PENDING) - items 1 and 2 of the remedy. domain_add refuses a dotless host and refuses a host disagreeing with its own site_url; domain_set applies the agreement check to site_url edits but not the dot check, so an existing bad row can still be removed. Pulled forward from its edge soak on the release manager's reasoning that multi-site behaviour is only exercisable where multiple sites exist. NOT SHIPPED: item 3 (log when a Host matches no registered domain and the default answers) and the fourth item added here - preview naming the Host it used. Both remain the right fixes for the DIAGNOSTICS, which is what made this cost an afternoon; registration validation only prevents new instances of it. ORIGINAL FILING FOLLOWS. FILED 2026-08-20 from the operator's own staging instance, and the reported symptom was the OPPOSITE of the fault. The report was that the domain check looks up 'dhcf' rather than the full name and must be checking the wrong thing, since https://dhcf.sites.lazysite.io serves. THE CHECK IS CORRECT AND THE SITE IS NOT SERVING. That URL returns 200, and what it returns is the PRIMARY staging site - <title>Lazysite staging</title>, theme assets under lazysite-assets/atelier/ - not the DHCF site, which is configured with layout dhcf, theme dhcf-r2 and content_root sites/dhcf. Verified by fetching it. The content root exists and is populated, so nothing is lost; it is simply not reachable. THE MECHANISM: the domain is registered with host 'dhcf' and site_url https://dhcf.sites.lazysite.io. Wildcard DNS lands the request on the instance carrying Host: dhcf.sites.lazysite.io. lazysite-processor.pl builds %declared from alias_hosts and tests $declared{$req_host} where $req_host is the full sanitised Host - so 'dhcf' never matches, no alias overlay is applied, and the request falls through to the base conf, which is the primary. _valid_host in Manager/Domains.pm requires only that each dot-separated label be well formed, so a single label passes and domain_add accepts it. THREE DEFECTS, one data error: (1) a host with no dot cannot appear as a public Host header on a public instance and should be refused, or at minimum warned about, at domain_add; (2) an alias host that disagrees with the hostname in its OWN site_url is self-evidently wrong and nothing notices - that comparison is free and would have caught this at registration; (3) the failure is SILENT and lands in the SM248 class the code already names - the visitor is told whose site this is, incorrectly - except SM248 was about a favicon and this is the whole site. THE CHECK'S WORDING IS THE ONLY FAIR COMPLAINT: 'the host name does not resolve yet - add the DNS record' is true but misdirects, because the DNS is fine and the registered name is not a hostname. It sent the operator to their DNS provider to look for a fault that is in the conf. REMEDY for the instance is to re-register under the full name; remedy for the engine is items 1-3, held for decision."
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

# The one field that cannot be corrected

`host` is not in `@DOMAIN_KEYS`, so `domain_set` refuses it: every other
setting on a domain can be edited in place, and the name cannot. There is no
rename verb.

::: widebox
So the single field whose error is SILENT and TOTAL - wrong name, no match, the
whole site replaced by the primary - is also the only one with no repair path.
That is the argument for validating it at `domain_add`, and it is stronger than
the tidiness argument: a value that cannot be edited afterwards has exactly one
moment when it can be got right.
:::

Over MCP it is narrower still. The connector exposes `list_domains` and
`domain_set` and neither `domain_add` nor `domain_remove`, so an agent can set
every field on a domain except the one that is wrong, and cannot re-register
it. Correcting this needs the manager UI or the control API.

# What the repair costs today

`domain_remove` strips the host from `alias_hosts` and every
`alias.<host>.*` line with it, so a rename is remove-then-add and the caller
must carry every override across by hand. Reading the current values first is
not optional - nothing else holds them once the remove lands.

`domain_add` does accept every domain key as an option and ADOPTS an existing
content-root directory rather than recreating it, so the round trip is lossless
when it is done carefully. The risk is not the content; it is the four or five
presentation settings that quietly revert to inherited if the re-add omits
them, which looks like a working site with the wrong appearance.

A `domain_rename` verb - rewrite `alias_hosts` and re-key the `alias.<host>.*`
lines in one write - would remove the hand-carrying and the window where the
domain is registered with nothing set. Worth weighing against just refusing the
bad value at the point of entry, which is cheaper and prevents rather than
repairs.

# Every diagnostic confirmed the broken config

Independently reproduced from a second session configuring the same staging
subdomain, whose operator-visible symptom was different and equally
misdirecting: *the theme selected doesn't seem to be the one delivered*. The
default site answered, over a valid certificate, with a real page.

The costly part is that all three tools an operator would reach for agreed the
configuration was fine:

```datatable
columns: Tool | What it said | Why
widths: 5cm | 6cm | X
bold: 1
tone: medium
---
`domain-preview` | renders the DHCF site perfectly | **feeds the stored key back in as the Host**
`domains-list` | a complete, correct-looking record | it reports what is stored, and the storage is intact
`domain-check` | "add the DNS record" | it resolved the literal string `dhcf`
```

::: widebox
`domain_preview` sets `$ENV{HTTP_HOST} = $host` from the STORED key, so the
processor's `$declared{$req_host}` lookup matches by construction. **The
preview validates the configuration against itself.** It can never detect a
host-key mismatch, because the mismatch is precisely between the stored key and
a real request's Host - the one difference the preview removes.

That is the defect worth fixing beyond the validation: the tool that exists to
answer "will this serve?" cannot see the failure mode that stops it serving.
:::

# Remedies, in the order the field suggests

1. **Refuse or normalise a dotless host at entry.** Cheapest, and the only
   moment the value can be got right (see the repair section above).
2. **Make `domain-check` evaluate the stored value the way a request would** -
   and distinguish "this name has no DNS record" from "this name cannot have
   one".
3. **Log when a Host matches no registered domain and the default answers.**
   The engine currently cannot know it is disappointing anyone; one line turns
   a silent fallthrough into something greppable.

Preview is the fourth: it should say which Host it used, so "it previews fine"
stops being mistaken for "it will serve".

# A smaller one alongside it

`domain-add` takes every parameter from the JSON body. A query-string call
therefore arrives with no `host` at all and is answered `Invalid domain host`,
which reads as *your hostname is malformed* rather than *you sent none*. Same
class as the DNS message: accurate about the internal state, misleading about
what the caller should change.
