---
id: SM922
title: "SM922: the link audit reports things that are not links, and scans its own report"
subtitle: "An operator ran it on a live site and got ten broken internal links. Checked one by one across four runs: two were real and in SHIPPED documentation, and every other entry traced to one of six faults in the audit itself - extraction over code and examples, relatives resolved against the site root, system pages resolved without the fallback chain, draft sections resolved anonymously, and the plugin reading its own last report as site content. The count moved 10 -> 8 -> 10 -> 7 with no change to the site."
brand: plain
standard-margins: true
status: shipped
raised: 2026-09-30
raised-by: site agent, from an operator's run on opendigital.cc (0.14.4), four runs
area: plugins
status-note: "SHIPPED (018b634f) 2026-10-01 - all six faults and the report store, which the ruling said land together. MEASURED, before and after, on the shipped docs corpus plus the shapes the filing names (tmp/measure-audit-noise.sh): ELEVEN broken links became ZERO, with the gated target reported in its own section - and a deliberately dead prose link added afterwards is still reported, so the gate was checked for having gone blind rather than quiet. (1) EXTRACTION IS FROM PROSE: fenced blocks, script and style elements, indented examples and inline code spans are removed before matching, keeping their newlines so nothing that counts lines is thrown out. The JavaScript index call in a script block - the entry that read as a site bug - is gone. (2) RELATIVES RESOLVE AGAINST THE PAGE: `key` on /manager/handlers is manager/key, not /key, and `../` climbs; a link that climbs out of the docroot is dropped. (3) SYSTEM PAGES GO THROUGH THE FALLBACK CHAIN, so /login is not broken when the engine default exists - and the table naming those pages had to move ABOVE the main body, because a file-scoped `my` below it is still empty when the collector runs: the check silently did nothing until the before/after sweep still showed /login and exposed it. (4) WITHHELD IS ITS OWN STATE per the ruling: a target found in the private store is reported separately, the audit stays anonymous, and the section says it DECLINED TO JUDGE rather than implying the link resolves. (5+6) THE REPORT IS A STORE, not a page: lazysite/audit/link-report.json, which the page walks already skip by path, so the audit cannot find it however the extractor changes. The action returns the findings in its own result; the manager renders them in a modal with a REFRESH that re-runs the audit, replacing the static card and the fetch-and-parse-a-page code; `on_complete => open_url` and the 90-line Markdown builder are gone. The page every site already has is DELETED on the next run, and is ignored by the walks through the same one spelling - without the ignore, the first run after upgrade would have reported the stale page one last time, on the very run that was supposed to end the instability. ALSO FIXED, the two real links the filing found plus the third it noticed: starter/docs/configuration.md now points at the views feature page and at ai-briefing-layouts, and views.md's see-also at ai-briefing-layouts. (starter/docs/features.html carries the same dead link and is NOT shipped - it is gitignored build output.) Nine sabotages, nine refusals. Original ruling follows. RULED 2026-09-30. Five of the six faults are plain repairs needing no decision; fault (4), protected sections, needed one. RULING: the audit KEEPS RESOLVING ANONYMOUSLY, and a target it could not see is reported as ITS OWN STATE, separate from a target that is missing - the four-state rule applied to a link, where `withheld` is not `absent`. Resolving as the operator running the audit was declined as the most work for a benefit that is not yet evidenced, and it would put a principal into a report that gets WRITTEN INTO THE DOCROOT, where a reader who could not see the gated page could read its path out of the report - a disclosure this filing would then have created. Skipping protected sections was declined because gated help would then never be audited at all, so a broken link inside it stays broken indefinitely. WHAT THE RULING DOES NOT GIVE: nobody can confirm from the report that a gated link actually resolves - only that the audit declined to judge it. That is honest and it is less than the operator wants; if it turns out to matter, resolving as the operator is the next step and this ruling does not foreclose it. LANDS WITH IT, same root: the report has nowhere of its own to live. Faults (4) and (6) and the release manager's own observation are all the consequence of the report being written into the docroot AS A PAGE - which is why the audit can scan its own last report, and why the result is displayed by fetching a URL into a static card with no way to re-run it. The report needs its own store and its own modal with a refresh, and that is one piece of work rather than three."
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

Protected sections needed a ruling rather than a fix. The audit resolves as an
anonymous visitor, which is right for a public site's public links and wrong for a
manager page linking into gated help. The options were to resolve as the operator
running the audit, to report withheld targets as a separate state from missing
ones, or to skip protected sections and say so in the report. The first is the most
useful and the most work; the second is the four-state rule applied to a link.

## Ruled 2026-09-30: withheld is its own state, and the audit stays anonymous

**The audit keeps resolving anonymously, and a target it could not see becomes its
own state rather than a false positive.** `withheld` is not `absent`, which is the
rule the engine already applies to its stores.

Resolving as the operator was declined on a reason this filing did not raise and
should have: **the report is written into the docroot as a page.** An audit running
with the operator's identity would put the paths of pages a reader cannot see into
an artefact that reader can fetch. That is a disclosure this filing would have
created while fixing a false positive, and it is the same root as fault (6).

Skipping protected sections was declined because gated help would then never be
audited, so a genuinely broken link inside it stays broken indefinitely - on a
site with a lot of protected material the audit would quietly cover very little.

**What the ruling does not give, said plainly:** nobody can confirm a gated link
actually resolves. The report says the audit declined to judge it. If that turns
out to matter, resolving as the operator is the next step and nothing here
forecloses it - but it needs the disclosure question answered first.

# And the report has nowhere of its own to live

Related, raised separately by the release manager while this was being read: the
report renders into a STATIC card on the Extension Config page rather than its own
modal, and there is no way to re-run it from where you are reading it. That is the
same root as fault six - the report is written into the docroot as a page, which is
both why the audit can scan it and why it is displayed by fetching a URL into a
card. Worth deciding together rather than separately.

**Confirmed as one piece of work by the 2026-09-30 ruling, and it is now three
things with one cause.** Fault (6) (the audit scans its own report), the static
card with no refresh, and the disclosure risk that decided fault (4) all follow
from the report living in the docroot as a page. It needs its own store and its own
modal with a Refresh that re-runs the audit. Fixing the six extraction faults
while leaving the report a page would leave the audit still able to find it.

# Related

[[SM201]] (the fallback chain the audit does not use),
[[feedback_substring_matching_false_positives]],
[[feedback_absence_is_a_finding]],
[[feedback_a_boolean_has_four_states]] (withheld is not missing).
