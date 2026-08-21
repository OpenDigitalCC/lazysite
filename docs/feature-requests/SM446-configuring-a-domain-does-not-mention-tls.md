---
title: "SM446: configuring a domain says nothing about TLS, and nothing notices until a visitor does"
subtitle: "The domain is added, the content root is provisioned, the settings are right - and the certificate does not cover the host. The check that diagnoses it precisely is one nobody is prompted to run."
brand: plain
standard-margins: true
status: candidate
status-note: "FILED 2026-08-21 from a field pass on edge 0.10.20. edge3.explore.lazysite.io is configured correctly in every respect the manager knows about - registered, content_root sites/edge3, layout publicsector - and has no usable TLS: curl fails hostname verification, and the certificate actually served covers isp.cloudient.net. NOT AN ENGINE DEFECT and the filing says so plainly. lazysite does not issue certificates and should not; adding a domain here is telling this instance to serve a name, and the certificate is the front end's business. THE GAP IS THAT NOTHING SAYS SO AT THE MOMENT IT MATTERS. The Add-a-domain flow provisions a content folder, seeds a page, and reports success, so every signal the operator receives says the domain is ready. The first thing that disagrees is a browser, belonging to a visitor. WHAT ALREADY WORKS, and is the reason this is a small change rather than a feature: domain-check diagnoses it exactly - 'a certificate is served (covers isp.cloudient.net) but not this host - add this host to the certificate (e.g. via Hestia SSL)'. That is a genuinely good message: it names what was found, what is missing, and where to fix it. The reporter drew the contrast themselves with SM436, where a bare label produced a confidently wrong answer about DNS. So the tool is right and the prompt to use it is missing. SUGGESTED, smallest first: after a successful domain-add, run the check automatically - or at minimum say 'TLS is not configured by this step; run the domain check' - and surface a persistent state on the Domains row for a domain that has never passed one. The point is not to nag but to close the gap between 'lazysite is done' and 'a visitor can reach it', which the operator currently discovers from the visitor. NOT PROPOSED: issuing or renewing certificates, or reaching into Hestia. That is the front end's job and the boundary this project keeps deliberately."
---

# What the operator is told, and what is true

```datatable
columns: Signal | Says
widths: 7cm | X
bold: 1
tone: medium
---
Add a domain completes | success
Content folder | provisioned, seeded
Domains list | complete, correct record
Settings (layout, content root) | all as configured
**A visitor's browser** | **certificate does not cover this host**
```

::: widebox
Every signal the manager gives says ready. The first thing that disagrees
belongs to somebody else, and arrives after the site is supposed to be live.
:::

# The tool is already right

`domain-check` answers precisely:

> a certificate is served (covers isp.cloudient.net) but not this host - add
> this host to the certificate (e.g. via Hestia SSL)

That names what was found, what is missing, and where to fix it. It is a
notably better answer than the one a bare label got in SM436, where the same
family of check reported a DNS fault that did not exist - and the contrast is
worth keeping, because it shows the difference is in the DIAGNOSIS, not in the
plumbing.

So nothing needs inventing. What is missing is any reason for the operator to
run it before a visitor does.

# Suggested, smallest first

1. **Run the check automatically after a successful `domain-add`**, and show
   its result in the sheet. The operator is already there, and it is the moment
   the answer is useful.
2. If that is too eager, **say it**: "TLS is not configured by this step - run
   the domain check once DNS and the certificate are in place."
3. **Show a state on the Domains row** for a domain that has never passed a
   check, so an instance with eight domains does not hide the one that cannot
   be reached.

# Not proposed

Issuing or renewing certificates, or reaching into Hestia. lazysite does not
own the front end and should not learn to; adding a domain here means telling
THIS instance to serve a name, and it is right that the certificate lives
elsewhere. The gap is a missing sentence and a missing prompt, not a missing
feature.
