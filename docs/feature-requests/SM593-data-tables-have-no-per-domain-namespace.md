---
title: "SM593: data tables have no per-domain namespace, so manage_data is instance-wide"
subtitle: "Multi-domain hosting separates content root, nav, theme and layout. Tables sit outside that split: one namespace, one flat list, shared by every domain on the instance."
brand: plain
standard-margins: true
status: candidate
status-note: "FILED BY THE SITE AGENT 2026-08-25 from the jpm-stock build, with a deadline attached: sites.lazysite.io carries six domains belonging to six unrelated parties (xisl, sjm, dhcf, jpm-stock, learning, mm-gallery), and the jpm-stock application is a work queue held in tables that needs four named customer staff to hold manage_data. manage_data is an INSTANCE capability and a table's ACL path is lazysite/db/tables/<name> with no domain component, so those four would - absent a deliberate ACL - read every table on the instance, including any the other five domains declare later. The table NAMES are their own disclosure: an unpublished table is invisible to an anonymous visitor precisely so names cannot be guessed, and that protection does not extend to a signed-in account on a neighbouring domain. A MITIGATION EXISTS TODAY and is sound - ACL lookup takes the longest matching prefix, so a restrictive rule on lazysite/db/tables plus a per-table rule for each site's own people closes it - but it depends entirely on somebody remembering, on a path that appears in no listing of the site being worked on. THE AGENT'S PREFERENCE ORDER: (1) scope tables to the declaring domain the way content_root scopes files, so data-tables lists that domain's tables and manage_data reaches no further - the answer that matches how the rest of multi-domain already behaves; (2) default the container ACL CLOSED on a multi-domain instance, private until widened; (3) say it in the docs - /docs/data-tables describes public: and the read list accurately and never mentions the namespace is shared, so a reader who understood that page completely would still walk into this. THE DOCS CHANGE IS WORTH MAKING EVEN IF (1) OR (2) SHIPS. SCOPE DECISION FOR THE OPERATOR: this is a feature, and under the 0.10.33 freeze it either joins that cut or waits until after beta - while the data plugin reaching sites.lazysite.io is what makes it urgent."
---

# Why this is not simply an ACL that nobody set

The default on a shared instance is **open between tenants**, and the thing
that closes it is an operator action on a path that does not appear in any
listing of the site being worked on. An agent building on `jpm-stock` sees
`data-tables` return `paintings` and `gallery` and has no reason to connect
those to a domain it is not working on.

# Proving tests

- On a two-domain instance, `data-tables` called in the context of domain A
  does not list domain B's tables, and `manage_data` held for A does not
  reach B's rows (fix 1); or a newly declared table is unreadable from
  another domain until a rule widens it (fix 2).
- `/docs/data-tables` states what the namespace is, whichever fix ships.
