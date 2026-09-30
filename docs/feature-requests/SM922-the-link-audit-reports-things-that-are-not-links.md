---
id: SM922
title: "SM922: the link audit reports things that are not links, and scans its own report"
subtitle: "An operator ran it on a live site and got ten broken internal links. Checked one by one across four runs: two were real and in SHIPPED documentation, and every other entry traced to one of six faults in the audit itself - extraction over code and examples, relatives resolved against the site root, system pages resolved without the fallback chain, draft sections resolved anonymously, and the plugin reading its own last report as site content. The count moved 10 -> 8 -> 10 -> 7 with no change to the site."
brand: plain
standard-margins: true
status: candidate
raised: 2026-09-30
raised-by: site agent, from an operator's run on opendigital.cc (0.14.4), four runs
area: plugins
---

# The two real ones, and they are ours

`/docs/views` does not exist, and two SHIPPED pages link to it - measured 404 on
0.14.4 and on edge at 0.15.0, with nothing under `/docs/` on edge carrying "view"
in its URL, so the page is not merely moved:

    docs/configuration.md:294  `children` keys. See [Views](/docs/views) for looping examples.
    docs/configuration.md:436  See [Layouts and themes](/docs/views) for installation and ...

The second is worse than a dead link: the text says **Layouts and themes** and
points at `/docs/views`, which reads as a link copied and not retargeted - a reader
following it wants `ai-briefing-layouts`.

`docs/features/configuration/views.md` links to `/docs/views` as well, so a page
links to itself by a path that does not resolve, which suggests the file moved
under `features/configuration/` and its own cross-references did not follow. A
third occurrence in that file's see-also list was NOT reported by the audit.

These are in every site's docroot. The reporting site was patched at the
operator's instruction, and that patch will be overwritten on upgrade - the fix
that lasts is here.

# The six faults, gathered

Across four runs, every entry the audit produced traced to one of these or to the
two links above.

```datatable
columns: Fault | Effect
widths: 5.6cm | X
text: 2
bold: 1
tone: medium
---
Extraction runs over code | two JS string literals and one JS function call read as links
Extraction runs over examples | `![](img/…)` and `[Book a visit](/visit)` read as links
Relatives resolved against the site root | `key` on `/manager/handlers` reported as `/key`, not `/manager/key`
System pages resolved without the fallback chain | `/login` reported broken while it answers 200
Protected sections resolved anonymously | draft and gated pages reported broken for the readers who can see them
Its own report is scanned | last run's findings re-reported, and the count is unstable between runs
```

Three of those are worth stating plainly because each is a different kind of
mistake:

**`](key)` is not a link.** The line is `body.innerHTML = BUILD[listId](key);` - a
JavaScript index followed by a call, matched by a markdown-link pattern inside a
`<script>` block. The docs corpus is precisely the content guaranteed to contain
example markup and embedded scripts, and it is the corpus the engine ships into
every docroot, so every operator who runs this plugin sees this.

**`/login` answers 200.** The shipped check asserts exactly that - *"system pages
(login/claim/40x) all resolve via the fallback chain (SM201)"*. So the audit
reports broken what the check reports sound, on the same site at the same moment.
One of them has to move and it is not the check.

**The audit scans its own report.** `manager/audit-report.md` is written by
`plugins/audit.pl`. Each run therefore reads the previous run's report as site
content and reports the links listed in it as broken links found on that page - in
the third run, three entries were attributed to the report itself, and they were
exactly the set the second run had listed. They vanished in the fourth run because
the report was rewritten, not because anything about those pages changed. That is
why the count moved with no change to the site.

**Draft is not missing.** After `/docs/` was protected as draft, two entries
remained whose targets exist and fetch 200 over WebDAV - they answer 404
anonymously because draft withholds the section's existence. An operator who
protects a section while writing it, or gates one behind a read list, gets every
link into it reported broken. For a manager help link the audience that can see
the section is the only audience there is. This was predicted in writing before the
run that produced it.

# Why it matters more than a wrong count

Of ten reported, three resolved perfectly, at least two were deliberate examples,
and the two real ones sat in the middle of the list with nothing to distinguish
them. A maintainer sees 10 and has about 3 to act on. A check whose output is
mostly noise does not get read, and then the real entries are invisible - which is
worse than no check, because the absence of a check is at least known.

# Suggested order

1. Fix the two `/docs/views` links, and the third in `views.md`'s see-also list
   that the audit did not report. Decide whether the second should point at
   `ai-briefing-layouts`.
2. Exclude the plugin's own output from its own scan. One line, and it is the fault
   that makes the count untrustworthy between runs.
3. Extract from PROSE: skip fenced blocks, indented examples, `<script>` and
   `<style>`.
4. Resolve the way the site resolves - relatives against the page's own directory,
   system pages through the fallback chain, and a decision about protected
   sections.

(2) and (3) are what make (1) findable next time rather than three real links
hidden in ten.

# The question inside (4)

Protected sections need a ruling rather than a fix. The audit resolves as an
anonymous visitor, which is right for a public site's public links and wrong for a
manager page linking into gated help. The options are to resolve as the operator
running the audit, to report withheld targets as a separate state from missing
ones, or to skip protected sections and say so in the report. The first is the most
useful and the most work; the second is the four-state rule applied to a link.

# And the report has nowhere of its own to live

Related, raised separately by the release manager while this was being read: the
report renders into a STATIC card on the Extension Config page rather than its own
modal, and there is no way to re-run it from where you are reading it. That is the
same root as fault six - the report is written into the docroot as a page, which is
both why the audit can scan it and why it is displayed by fetching a URL into a
card. Worth deciding together rather than separately.

# Related

[[SM201]] (the fallback chain the audit does not use),
[[feedback_substring_matching_false_positives]],
[[feedback_absence_is_a_finding]],
[[feedback_a_boolean_has_four_states]] (withheld is not missing).
