---
title: "SM332 - Promote a scanner by behaviour, not only by signature"
subtitle: "A WordPress path sweep - ten distinct 404s from one visitor in a few minutes - is classified as human, because the modern probe is extensionless and every trigger in the probe list is a signature that predates it."
brand: plain
status: shipped
status-note: "SHIPPED for 0.10.12. A second trigger on SM213's existing visitor-level pass, not new architecture: a token asking for five or more DISTINCT missing paths inside five minutes is promoted to `scanner`, and its other requests that day go with it - which is what pulls the sweep's homepage hit out of the journey metric, the reason this mattered out of proportion to its 4%. Distinct paths and a short window are what separate it from the case it must not catch: a reader following stale bookmarks, whose `not_found.plausible` entries are the more useful signal of the two. Both numbers are settings with stated defaults, per the filing - how many 404s a real reader generates is a property of the site. The day and month rollups carry `scanner_inferred`, so an operator can see how much of their scanner class was inferred and judge the threshold against their own traffic rather than against ours. FILED 2026-08-16 from a partner-agent review of visitor statistics on edge/0.10.11."
---

# SM332 - the probe list dates, the behaviour does not

## What was measured

Six visitor tokens, every request a 404, all classified `human`:

```
/wp-json/batch/v1            /old/wp-json/batch/v1
/wp/wp-json/batch/v1         /test/wp-json/batch/v1
/wordpress/wp-json/batch/v1  /dev/wp-json/batch/v1
/blog/wp-json/batch/v1       /backup/wp-json/batch/v1
/wp/                         /config
```

That is one visitor walking a list of guesses at where a WordPress install
might be mounted. It is the behaviour [[SM213]]'s visitor-level classification
was built to catch, and it is not caught.

## Why it escapes every trigger

`_is_probe` promotes a visitor to `scanner` on four conditions:

```datatable
columns: Trigger | Why this sweep misses it
widths: 5.4cm | X
bold: 1
tone: medium
---
`NOISE_RE` | The paths are not on the list
`\.php` extension | The WordPress REST API is extensionless
`SECRET_RE` | Not a secrets file, key or credential
404 on `SPA_MANIFEST_RE` | Not an SPA or build manifest
```

`/wp-login.php` is caught, by the `.php` rule. Its modern replacement,
`/wp-json/...`, is caught by nothing.

That is the general problem rather than a gap in one list. **The triggers are
signatures, and signatures date.** This one dates precisely: it recognises the
WordPress probe of several years ago and not the one being run against the
instance today. Adding `/wp-json` closes this instance and not the next.

## Why it matters more than 4% suggests

By volume it is negligible: 27 events across 6 tokens, 4% of human-class events
in the sample.

By effect it is not, because **classification quality gates everything built on
top of it**. Modelling the path-pair transitions proposed in the statistics
review against today's data, using human-class events only:

```
    5  / -> /wp-json/batch/v1
    4  / -> /support
    2  /wp/ -> /wp/wp-json/batch/v1
```

The most travelled journey on the site is a vulnerability scan. A site owner
shown that would draw a conclusion about their visitors that is entirely wrong,
and the more useful the downstream metric becomes, the more damage a
misclassified visitor does.

It also inflates the headline human number, which is the figure customers quote.

## The proposal

**A visitor generating many 404s on distinct paths in a short window is a
scanner, whatever the paths are.**

Behavioural rather than signature-based, so it needs no maintenance as probe
fashions change, and it would have caught this pattern on the day it first
appeared rather than whenever somebody noticed.

The machinery exists. SM213 already flags a visitor token as `scanner` for the
window in a first pass over the day's events, and reclassifies that token's
other requests as a side effect. This is a second trigger on that pass, not new
architecture.

Three parameters, and the values are the maintainer's call:

Distinct 404 paths
: The count that constitutes a sweep. Distinct matters - one path retried is a
  broken link or a stuck client, not a scan. Five is a plausible starting point.

Window
: Short enough to separate a sweep from a day's browsing. Minutes rather than
  hours.

What counts
: Only 404s, and only paths that are not already `noise` - a visitor who fetches
  a missing favicon and a missing robots.txt has not swept anything.

## What to be careful of

**A real person can generate 404s.** Someone following a set of stale bookmarks,
or a broken navigation menu, produces several 404s in a short time. That is why
the threshold should be on *distinct* paths and should not be low, and why this
should be a setting rather than a constant.

**The interesting case is the one to protect.** [[SM213]] records that the
`not_found.plausible` split exists to surface exactly that reader - a person
hitting a real-looking missing page is signal for the site owner. A behavioural
promotion must not swallow them, so `plausible` 404s should probably weigh less
than junk ones, or be excluded from the trigger entirely.

**It should be visible.** If a visitor is promoted by behaviour rather than by
signature, that is worth distinguishing in the day rollup, so an operator can
see how much of their scanner class is inferred and check the threshold against
their own traffic.

## Verification

- A visitor requesting five or more distinct non-existent paths inside the
  window is classified `scanner`, and their other requests that day with it.
- The sweep above, replayed as a fixture, is classified `scanner`.
- A visitor hitting three 404s from stale bookmarks stays `human`.
- A visitor hitting the same missing path repeatedly stays `human`.
- `not_found.plausible` still records the missing pages a real reader looked for.
- The rollup distinguishes signature-promoted from behaviour-promoted tokens.

## What shipped, and what was chosen

```datatable
columns: Decision | Value | Why
widths: 4.2cm | 2.6cm | X
bold: 1
tone: medium
---
Distinct missing paths | 5 | High enough that a reader who mistypes twice is untouched. Distinct, not requests - one path retried is a stuck client
Window | 5 minutes | A day's browsing is not a sweep however many dead links it turns up
What counts | 404s only | And only from a token not already promoted by signature
Attribution | `scanner_inferred` | Per day and per month, so the threshold can be judged against real traffic
---
```

**Signature wins the attribution.** A token caught by both triggers is recorded
as caught by signature, because that is the cheaper and the more certain of the
two, and the inferred count is only useful if it means what it says.

**The state is bounded and transient.** The per-token path set lives in the
export cache beside SM213's scanner map, self-obsoletes on a salt roll, is
capped, and is discarded for a token the moment it is promoted - so the map
holds only visitors who are still under the threshold.

**The false-positive cases are three of the five tests**, not an afterthought:
three dead bookmarks stay human and keep their `plausible` 404s; one missing
path requested twelve times stays human; and the same eight missing paths that
are a sweep in three minutes are an ordinary bad afternoon spread over an hour.

## Related

[[SM213]] (visitor-level scanner classification, and the pass this extends),
[[SM192]] (the signature lists, and `noise_paths` as the precedent for an
operator-set escape hatch), and
`inbox/visitor-stats-what-must-be-recorded-now-2026-08-16.md`, which sets out
what would be built on top of this.
