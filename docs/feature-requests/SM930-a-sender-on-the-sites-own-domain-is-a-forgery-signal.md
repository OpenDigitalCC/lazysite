---
id: SM930
title: "SM930: a sender on the site's own domain is a forgery signal the engine can apply itself"
subtitle: "One of six spam submissions to a customer site gave its email address as someone@<that site's own domain>. Nobody outside an organisation legitimately fills in its public enquiry form as one of its own people, and every site already knows its own domain - so this is a heuristic the engine can apply without the operator having to think of it. Simulated against nine real submissions: 6 of 6 junk quarantined, 3 of 3 genuine delivered."
brand: plain
standard-margins: true
status: candidate
raised: 2026-09-30
raised-by: site owner's observation, relayed by the site agent with a simulation against nine stored submissions (0.15.0)
area: forms
---

# The observation, and it is the site owner's

Nine enquiries were stored on a customer site; six were commercial spam. The owner
noticed what the agent had not: **one of them set the sender address to an address
on the site's own domain.**

    18/09  posture-corrector advert     email domain: <the site's own>

The other five used their own domains or a free mailbox; the genuine three used a
`.gov.uk` and a `.edu` address.

# Why it is a good signal

A public enquiry form is for people outside the organisation. Somebody inside it
has a mailbox, a phone and a colleague; they do not write to themselves through
the website. So an address in the site's own domain on an **unauthenticated**
submission is one of:

- a forgery, which is what this was;
- a staff member testing the form, who loses nothing if the submission is
  quarantined rather than announced.

It is cheap, it needs no list to maintain, and **every site already knows its own
domain** - `site_url`, and the host the request arrived on. Unlike a keyword list
it does not go stale, and it costs an operator nothing to benefit from.

# What was done on the site, and why it is not the answer

`spam_keywords` is a case-insensitive substring match across every submitted
field, so the rule can be expressed today as a keyword - `@<own-domain>` in the
list. Applied to all three forms and **simulated against the nine real
submissions first: 6 of 6 junk quarantined, 3 of 3 genuine delivered, no false
positives.** The own-domain rule is what catches number 4 on its own; the URL
threshold and a `% off` keyword catch it too, so it is belt and braces there.

**Grade: measured, against a real population, before being proposed.** That is
also the reason the workaround is known to work and known to be the wrong shape.

It is the wrong shape because every operator on every site has to think of it
independently and write their own domain into a keyword list, and it silently
stops working the day the site moves domain.

# Suggested

Add it to `_spam_assessment` beside the existing heuristics (`_disguised_link`,
`_one_value_everywhere`, the URL threshold): when a submitted field holds an email
address whose domain matches the **site's own** domain, and the submission is
unauthenticated, add a reason - *"sender claims an address at this site's own
domain"*.

Two details worth getting right:

- **Match the registrable domain, not the exact host**, so `www.` and a subdomain
  site both work. Not a substring match on the domain - `notxisl.com` ends with
  `xisl.com` and is a different organisation, which is the trap
  [[feedback_substring_matching_false_positives]] exists for.
- **Make it defeasible** for the case where it is legitimate - a site whose form
  IS for internal use. The existing `quarantine: off` covers that, or a named key
  if finer control is wanted.

Quarantine is the right severity: stored, not announced, recoverable from the
Submissions page. Nothing is lost if the guess is wrong.

# Worth noting about the default

The shipped `spam_url_threshold` of 2 let three of these six adverts through, each
carrying a single link. For a form about batch and text processing, one link is
already unusual. The default is defensible for a general contact form; it is worth
knowing that it passes single-link advertising, which is the common shape.

Not proposed as a change here - lowering it is exactly the sort of tuning that
should be measured against a real population first, and the population that
exists is nine submissions on one site.

# Related

[[SM216]] (the quarantine scoring this belongs in), [[SM929]] (the other finding
from the same nine submissions), [[feedback_substring_matching_false_positives]],
[[feedback_no_substring_country_matching]] (the same trap, named for a different
field), [[feedback_spam_reports_to_dev_inbox]].
