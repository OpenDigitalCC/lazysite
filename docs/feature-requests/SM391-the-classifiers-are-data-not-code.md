---
title: "SM391: the visitor classifiers are data, updatable without editing the engine"
subtitle: "Every classifier is a signature list, and signature lists date. SM332 is the proof: /wp-login.php was caught and its modern replacement /wp-json/batch/v1 was caught by nothing, because updating a signature meant releasing the engine."
brand: plain
standard-margins: true
status: shipped
status-note: "BUILT 2026-08-19. The eight pattern sets are loaded from lazysite/stats/classifiers.json when present, extending the built-ins. Three failure directions are tested rather than assumed: a broken file falls back entirely, one bad pattern costs that rule alone, and the ruleset in force is stamped into the export beside counting_basis. EXTEND rather than replace was the second design - the first replaced, and the test caught that adding one crawler signature would silently lose curl, wget and the rest."
---

# Why

Every pattern in the stats plugin is a signature list. [[SM332]] is what
that costs: `/wp-login.php` was caught by the `.php` rule, its modern
replacement `/wp-json/batch/v1` was caught by nothing, and a WordPress
enumeration ran as `human` until somebody noticed months later.

The gap was not the pattern. It was that changing a pattern meant
editing, testing and **releasing the engine**.

# The shape

`lazysite/stats/classifiers.json`, optional:

```json
{
  "version": "2026-08-19-a",
  "rules": { "bot": "someNewCrawler|anotherOne" }
}
```

Eight rules can be extended: `noise`, `infra`, `secret`,
`spa_manifest`, `asset`, `bot`, `agent`, `ai`.

# Three failure directions, which is what the tests are about

::: widebox
**A broken file must not disarm the classifier.** An unreadable or
malformed ruleset falls back to the built-ins entirely. Classifying
nothing - or everything as human - is a silent and total failure of the
thing an operator reads numbers from, and it would look like a quiet
change in traffic rather than a fault.
:::

**A bad pattern must cost that rule, not the file.** Each compiles on
its own; one that will not compile is skipped and reported and the rest
still apply. A file rejected wholesale for one typo makes every edit an
all-or-nothing risk, which is how people stop editing.

**The ruleset must be attributable.** Its version is stamped into the
export beside `counting_basis` ([[SM338]]), because "the numbers
changed" and "the rules changed" are different answers and a reader
cannot tell them apart otherwise.

# Extend, not replace - and the test found that

The first design replaced the built-in pattern. That is a foot-gun: an
operator adding one crawler signature would silently lose `curl`,
`wget`, `python-requests` and everything else, **and the loss shows up
as a rise in the human count rather than as an error**.

A ruleset now extends. `"replace": ["bot"]` is available for the case
where a built-in is wrong rather than incomplete, which is rarer and
should be deliberate.

# Verification

- A signature added by file classifies, with no code change, and the
  built-in matches survive alongside it.
- A malformed file classifies exactly as no file does - asserted with a
  client that DEPENDS on a built-in rule, because a fixture of unmatched
  clients cannot tell a working classifier from a disarmed one.
- A file with one uncompilable pattern still applies the others.

# Related

[[SM332]] (the signature that dated), [[SM338]] (the basis stamp this
sits beside), [[SM213]] (the classification it configures).
