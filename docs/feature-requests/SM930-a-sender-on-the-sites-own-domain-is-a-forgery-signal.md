---
id: SM930
title: "SM930: a sender on the site's own domain is a forgery signal the engine can apply itself"
subtitle: "One of six spam submissions to a customer site gave its email address as someone@<that site's own domain>. Nobody outside an organisation legitimately fills in its public enquiry form as one of its own people, and every site already knows its own domain - so this is a heuristic the engine can apply without the operator having to think of it. Simulated against nine real submissions: 6 of 6 junk quarantined, 3 of 3 genuine delivered."
brand: plain
standard-margins: true
status: shipped
raised: 2026-09-30
raised-by: site owner's observation, relayed by the site agent with a simulation against nine stored submissions (0.15.0)
area: forms
status-note: "SHIPPED (e1f7cf73) 2026-10-01: `spam_own_domain` sits beside the other three quarantine heuristics in `_spam_assessment` and is OFF BY DEFAULT, stated in ONE place (_load_form_conf) - a sabotage found the guard restating the same default a second time, where flipping it changed nothing a test could see, so the guard now fails safe without claiming to be the default. THE REASON STRING IS THE FILING'S OWN WORDS: `sender claims an address at this site's own domain`. THE OWN DOMAIN COMES FROM BOTH SOURCES THE FILING NAMES - `site_url` from the site config (interpolated, because it ships as `${REQUEST_SCHEME}://${SERVER_NAME}`) and the host the request arrived on, which SM926 ruled IS the host - and either being right is enough. TWO DECISIONS INSIDE THE RULING, both made to avoid a false positive the sender would never learn about. (1) IT MATCHES THE WHOLE FIELD VALUE, not an address inside a sentence: `I wrote to info@<this site> last week and heard nothing` is a GENUINE enquiry and the shape a frustrated customer writes. (2) IT NEVER STRIPS BEYOND `www.`. The filing asks for the REGISTRABLE domain and getting that right needs a public-suffix list this engine does not ship; a naive one-label strip would make a site at `mysite.github.io` match every other site on `github.io` and `example.co.uk` match the whole of `.co.uk`, which is the same class of error as the substring match the filing warns about. So the candidates are the host and the host without `www.`, and a subdomain of either matches on a LABEL boundary - `notexample.com` is not `example.com`. A site on `shop.example.com` therefore does not flag `someone@example.com`: a miss, chosen over a class of false positive that would quarantine strangers' real mail. The test replays the owner's own population shapes and half of it is the submissions that must still ARRIVE. Six sabotages, six refusals. NOT TOUCHED, as ruled: the shipped `spam_url_threshold` of 2 stays where it is - lowering it wants a bigger population measured first, and nine submissions on one site is not that. Original ruling follows. RULED 2026-10-01: SHIPPED AS A HEURISTIC, OFF BY DEFAULT, behind a named key. The rule itself is accepted - a public enquiry form is for people outside the organisation, and the site owner's own measurement stands: simulated against the nine real submissions before being proposed, 6 of 6 junk quarantined and 3 of 3 genuine delivered, with the own-domain rule the only signal that caught number 4 on its own. What is NOT accepted is turning it on for every site: a form that genuinely IS for internal use would start quarantining its real traffic on upgrade, and this engine does not change what a site already does without being asked. Off by default also answers the premise correction below, which the filing could not have known. ONE PREMISE CORRECTED BEFORE THE RULING WAS RECORDED. The filing conditions the rule on the submission being `unauthenticated`. THE ENGINE CANNOT TELL: a stored submission carries no actor at all, deliberately - form-handler.pl:153-163 removed `_auth_user` because it was forgeable and was reaching the audit trail's actor column, and SM924 re-measured and confirmed it. So there is no authenticated case to exempt and the rule would apply to EVERY submission, including a staff member testing the form from their own desk while signed in to the manager. That is survivable - quarantine is recoverable from the Submissions page and the filing says as much - but it is not the rule the filing described, and it is a second reason the default is off. WHAT THE BUILD MUST GET RIGHT: the REGISTRABLE domain, not the exact host and never a substring - `notxisl.com` ends with `xisl.com` and belongs to somebody else, which is the trap feedback_substring_matching_false_positives exists for; the site's own domain taken from what the site already knows (site_url, and the host the request arrived on - note SM926's ruling, that the presented host is the host); a reason string in the same voice as the existing three; and quarantine, never refusal. NOT RULED: lowering the shipped `spam_url_threshold` of 2, which let three single-link adverts through. The filing declines to propose it on a population of nine submissions on one site and that restraint is correct - it needs a bigger population measured first."
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
