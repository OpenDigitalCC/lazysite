---
id: SM913
title: "SM913: every genuine submission on a live contact form was spam, and the quarantine that exists to catch it counts URLs it cannot see"
subtitle: "Four of four non-test submissions on opendigital.cc's contact form are spam, each from a different address range, all stored and announced as ordinary enquiries. SM216's content quarantine was built for exactly this and its URL signal only counts a host written with a scheme - which is the one thing the reported spam deliberately avoids, writing its shortener as `brnd .li/delist`."
brand: plain
standard-margins: true
status: candidate
status-note: "RAISED 2026-09-28 from the crm-agent's read of all five exported submissions (evidence grade: read, not probe output). THE MECHANISM ALREADY EXISTS and this filing is mostly about why it did not fire: SM216 quarantines a suspect submission rather than refusing it - stored, kept off the notification bell, shown under the Submissions quarantine filter - default ON, on two content signals, `spam_url_threshold` (default 2) and an operator keyword list. MEASURED WEAKNESS IN SIGNAL ONE: the count is `() = $text =~ m{https?://}gi`, so it counts only a host written WITH A SCHEME. The reported Kind A pitches wrote their opt-out host as `brnd .li/delist` - a link-shortener domain with a space inserted to defeat link filters - which that pattern cannot see at all, and a bare `www.example.com` is equally invisible. FIRST QUESTION, AND IT IS A MEASUREMENT RATHER THAN A DESIGN: was quarantine ON for that form? If it was, then a pitch carrying two scheme-written URLs should already have been flagged, and the fault is in the counting rather than in the absence of a feature. If it was off, the default was overridden and that is worth knowing too. NOT PROPOSED: a CAPTCHA, a tracker, or blocking by address - the report measured four different source ranges, so an address rule would have caught none of the four."
raised: 2026-09-28
raised-by: crm-agent session, via the dev inbox
area: forms, anti-spam
---

# What was observed, and by whom

The crm-agent exported the five submissions held by opendigital.cc's contact
form (2026-07-19 to 2026-09-24) for loading into the CRM, opened every one, and
reported counts rather than estimates. One is the site agent's own delivery test
and was already flagged. **The other four are all spam, and none is an enquiry.**

They are two shapes.

| Kind | Count | The markers the reporter found in every one of them |
| --- | --- | --- |
| A - templated sales pitch | 3 | An opt-out footer of one shape - *"fill the form at `brnd .li/delist` ... with your domain address (URL)"*, the shortener host written with a SPACE; a fabricated postal address ending `CA, USA, <5 digits>` whose city is not in California; a pitch for a web service with one or two URLs, two of them on that same shortener; a free-mail sender; a long, salesy subject |
| B - gibberish | 1 | Name, subject and message are upper-case letter runs, each containing **the same 7-digit number**; a disposable-looking mail domain |

**Each of the four came from a different source address range.** The reporter
checked `_ip` per record and says so. Any rule about addresses would have caught
none of them.

# What already exists, and why this is not a request for a spam filter

[[SM216]] built the right thing and it is on by default. A suspect submission is
**quarantined, not refused**: stored, kept off the notification bell, shown under
the Submissions quarantine filter. The filing's own reasoning is the reason this
approach is safe - *"a false positive costs nothing (the message still arrives,
just unannounced), which is what makes cheap content heuristics safe on by
default"* - and it is why nothing here proposes rejecting anything.

Two signals, read from `plugins/form-handler.pl`:

| Signal | What it does | Against these four |
| --- | --- | --- |
| `spam_url_threshold`, default 2 | counts `https?://` in the visible text | catches a Kind A pitch **only if** two of its URLs are written with a scheme |
| `spam_keywords`, operator-supplied | a substring match, any hit | nothing is configured by default, so nothing fires |

# The measured weakness

    my $urls = () = $text =~ m{https?://}gi;

The count requires a scheme. So:

- `brnd .li/delist` - the exact string the reporter quotes, with the space that
  is there to defeat link filters - is **not a URL** to this counter.
- `www.example.com` is not either.

The spam is written by people who expect a link filter, and the shape they use to
dodge one also dodges the counting. That is not a subtle miss: it is the single
marker present in all three Kind A messages.

# What has to be measured before anything is built

**Was quarantine on for that form?** This decides which filing this is.

- If **on**, then at least the two-scheme-URL pitches should already have been
  flagged and were not, and this is a DEFECT in the counting rather than a
  missing capability. That would want reproducing against the stored records.
- If **off** - the key is `quarantine: off` in the form's own conf - then the
  default was overridden on a public form, and the question becomes why, and
  whether the manager surface makes that state visible to whoever did it.

The four records are on disk for inspection at
`/srv/projects/crm-agent/opendigital/contact/`, which is where the reproduction
starts. The form's conf is the site agent's to read.

# Proposed rows

Sizes are mine. Each is a signal for a shape these four actually have, and each
feeds the EXISTING quarantine state rather than a new outcome.

| Ref | Cx | What |
| --- | --- | --- |
| S1 | S | The URL count sees a host without a scheme, and one written with spaces or other separators inside it. A bare `www.host.tld`, a `host .tld/path`, and a scheme-written URL all count as one URL each. This is the row that would have caught all three Kind A messages. |
| S2 | XS | A shipped list of link-shortener hosts, counted as a stronger signal than an ordinary URL - a shortener in a first-contact message from a stranger is close to diagnostic, and the reporter found two of them on the same host. |
| S3 | S | **The same value repeated across every field.** Kind B's name, subject and message each carry the same 7-digit number. A submission whose fields are variations of one string is not a message anybody wrote, and this signal needs no dictionary and no list to maintain. |
| S4 | S | Report the quarantine STATE on the form, at the manager surface. An operator cannot tell today, from the page, whether a public form's quarantine is on - which is what makes the measurement above necessary rather than obvious. |
| S5 | XS | `spam_keywords` gains a shipped default list, or explicitly does not and says why. It is empty today, so signal two never fires unless somebody configures it, and nobody configures a thing they have not been told exists. |

S1 and S3 are the two that would have changed the outcome for all four records.

# What this filing refuses to propose

- **A CAPTCHA.** SM216 settled the position: content heuristics, server-side, no
  tracker and no puzzle. Nothing in these four changes that argument.
- **Blocking by address.** Measured useless here - four submissions, four ranges.
- **Refusing rather than quarantining.** A false positive on a genuine enquiry
  that happens to contain two URLs must cost nothing, and quarantine is what
  makes that true.

# One thing to notice about the acknowledgement path

[[SM877]] has just made it possible for a form to mail the address a submission
supplies. On this form, every genuine-looking submission for two months was
spam, so a site that turns that on should expect to answer spam - which is what
the per-recipient and per-site caps bound, and why they are not optional. A
quarantined submission not ringing the bell is one thing; a quarantined
submission that still sends a courteous reply to a stranger who chose the
address would be another. **Whether an acknowledgement should go for a
quarantined submission is a question this filing hands to SM877's row rather
than answering here** - and today it does go, because nothing tells the handler
what the assessment decided.

# Related

[[SM216]] (the quarantine, its signals and the reason it stores rather than
refuses), [[SM877]] (the acknowledgement path, and the question above),
[[feedback_negative_finding_needs_a_discriminating_measure]] (why the first
task here is a measurement and not a build).
