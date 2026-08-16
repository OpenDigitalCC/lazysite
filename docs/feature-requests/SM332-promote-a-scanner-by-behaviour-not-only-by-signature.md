---
title: "SM332 - Promote a scanner by behaviour, not only by signature"
subtitle: "A WordPress path sweep - ten distinct 404s from one visitor in a few minutes - is classified as human, because the modern probe is extensionless and every trigger in the probe list is a signature that predates it."
brand: plain
status: candidate
status-note: "FILED 2026-08-16 from a partner-agent review of visitor statistics on edge/0.10.11. Small in volume - 27 events, 6 visitors, 4% of human-class events in a 5,000-event sample - and out of proportion in effect, because it would be the top journey on the site the moment trail metrics exist. The mechanism already exists: SM213 promotes a visitor token to scanner for the window. This asks for a second trigger on it. The threshold is a judgement for the maintainer; the numbers below are a starting point rather than a recommendation."
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

## Related

[[SM213]] (visitor-level scanner classification, and the pass this extends),
[[SM192]] (the signature lists, and `noise_paths` as the precedent for an
operator-set escape hatch), and
`inbox/visitor-stats-what-must-be-recorded-now-2026-08-16.md`, which sets out
what would be built on top of this.
