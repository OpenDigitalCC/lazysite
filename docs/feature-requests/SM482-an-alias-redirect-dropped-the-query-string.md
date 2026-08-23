---
title: "SM482: an alias redirect kept the path and threw away the parameters"
subtitle: "On a live hosting site the query string WAS the payload - the affected customer's URL - and the alias discarded it while fixing the 404 that prompted it"
brand: plain
standard-margins: true
status: shipped
status-note: "REPORTED FROM THE FIELD, from a real customer-facing URL on cloudient.net. A hosted customer whose service is down lands on /forms/service-report.shtml?https://their-site/ - the query string IS the affected service, and the page reads location.search to render 'Affected service: <url>' with a link back. The legacy .shtml path is served by an alias; the alias resolved the path and discarded the payload. So the 404 was fixed and the thing the URL existed to carry was not, which is a worse outcome than the 404: a 404 is visibly broken, and a form that has forgotten what it is reporting on looks like it works. NOT A SPECIAL CASE - ?page=3, ?utm_source=, a search term, a session marker are all somebody's link, a 301 is expected to preserve them, and every other redirect in the processor already did. AN ALIAS TARGET MAY CARRY ITS OWN QUERY, since it is an author's front-matter string: the request's parameters are APPENDED with & rather than replacing it, because the author's say where they are sending people and the visitor's are what they arrived with. CR and LF are stripped from the query before it reaches the Location header - the same guard the alias target already had, now applied to the half that comes from outside, which is the half an attacker controls. FIVE SABOTAGES. One did not bite and the test was wrong rather than the code: `qr/\\?[^?]*\\z/` anchors on the LAST question mark, so `/landing?src=legacy?page=2` satisfied it - a regex that could not fail the thing it was written to catch. It counts them now."
---

# The URL that stopped working

```
https://cloudient.net/forms/service-report.shtml?https://ekaterina.media/
```

The conversion from the old Apache site aliased 18 legacy `.shtml` URLs and
missed 7, so this 404'd. Adding the alias fixed the 404 -- and then:

```datatable
columns: Request | Location, before
widths: 8.4cm | X
bold: 1
tone: medium
---
`/about.shtml?probe=1` | `/about`
`/resources/domains.shtml?x=y` | `/resources/domains`
`/forms/service-report.shtml?https://ekaterina.media/` | `/forms/service-report`
```

**The second state is worse than the first.** A 404 is visibly broken and gets
reported. A report form that has silently forgotten which service it is
reporting on looks like it works.

# Two queries, one URL

An alias target is an author's front-matter string and may already carry
parameters. Those say where the author is sending people; the request's are
what the visitor arrived with. Dropping either loses something, so they are
joined -- with `&`, because a second `?` makes everything after it part of a
parameter value.

# The half that comes from outside

The alias target has been CR/LF-stripped since SEC-2026-07, because it reaches
a `Location` header. The query string reaches the same header and comes from
the request, so it is stripped too. That is the half an attacker controls.
