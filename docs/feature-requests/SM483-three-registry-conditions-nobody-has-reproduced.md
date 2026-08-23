---
title: "SM483: three registry conditions nobody has reproduced"
subtitle: "Carved out of SM442 so a shipped fix could close and these could be owned. All three were observed on live sites, none has been reproduced, and none is explained"
brand: plain
standard-margins: true
status: candidate
status-note: "CARVED OUT OF SM442 ON 2026-08-23, because carrying them as an open note on a shipped fix meant a filing that could never be closed and a gap nobody owned. SM442 made regenerate-registries say what it CLEARED rather than what it considered, and that shipped; these three are separate field conditions that the fix does not address and was never going to. WHAT MAKES THEM ONE FILING rather than three: all three are a registry that does not hold what the site's content says it should, and the most likely explanations overlap - a per-domain path resolving somewhere unexpected, a write accepted by a channel that does not own the file, or a regeneration that ran against a different root than the one being read. NONE IS REPRODUCED. That is the first piece of work here, and it is deliberately not being guessed at: SM442's own fix exists because ninety minutes went into probing a symptom whose cause was not visible from the outside, and the answer was that the tool reported the wrong thing. The same trap is available here."
---

# The three

```datatable
columns: Condition | Where seen
widths: 7.4cm | X
bold: 1
tone: medium
---
A registry frozen -- kept advertising deleted pages through two regenerations | community.dhcf.eu
A registry empty from birth -- never populated at all | a xisl-family site
`sitemap.xml` accepted over WebDAV with a 201, and discarded | a content-root site
```

The third is the documented escape hatch: an operator who does not like the
generated sitemap is told to write their own. It is accepted and does not take
effect, so the remedy the documentation offers does not work.

# What is not known

Whether these are one fault or three. Whether any is specific to a
**content-root** site -- two of the three were, which is suggestive and is not
evidence. Whether the write path and the read path resolve the same file.

# Why this is filed rather than fixed

Nothing here has been reproduced on a fixture. SM442 exists because ninety
minutes went into probing a symptom whose cause was invisible from outside, and
the eventual answer was that the tool was reporting something other than what
it had done. Guessing at a cause and shipping a change against the guess is the
same mistake with a longer feedback loop.

**First work: reproduce one of them.** The content-root shape is the obvious
place to start, since two of the three had it.

# What is already done

`regenerate-registries` now reports what it cleared rather than what it
considered, so the next occurrence is diagnosable from the first response
instead of from a session of probing. That was SM442 and it shipped; it does
not fix any of the three above, and this filing exists so that saying so does
not require reopening it.
