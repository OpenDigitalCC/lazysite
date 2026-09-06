---
id: SM758
title: "SM758: the Groups page shows actions by category, alphabetised within, and the scheduler tick names its unit"
subtitle: "The release manager, 2026-09-06, on 0.13.2 edge: twenty-two action checkboxes in one run were a list to be read end to end; and a config field asked how often without saying in what."
brand: plain
standard-margins: true
status: shipped
status-note: "BUILT 2026-09-06 on claude/sm758-the-groups-page-shows-actions-by-category for 0.13.3. Actions grid drawn by ACTION_SECTIONS (Content, Appearance, Data, Site, Accounts, Operations, Insight), sorted by label within; channels sorted by label; anything unsectioned drawn under Other; t/lint/19 holds that the sections name exactly the ACTIONS keys, once each. daemon_tick_seconds labelled 'Seconds between the scheduler's checks for due work'."
---

# The feedback

> groups page - there are now many options, these should be categorised or
> alphabetised to make them easier to find. if they sit in logical categories
> then do that, alphabetised within. [...] thats under Actions - what they may
> do

> How often the scheduler looks for due work - this doesnt say what unit this is

# What was true

The Actions grid on the Groups page listed every action capability in the
order they were added to the engine: content first, then the ones each
release brought. At four that was a glance; at twenty-two it was a list an
operator read to the end to find the one they wanted, with `run_jobs` between
authoring briefs and housekeeping because that is when it arrived.

The daemon plugin's tick field carried its unit in its key
(`daemon_tick_seconds`) and nowhere the operator could see it. A field that
asks "how often" and takes a bare number is answered in whatever unit the
reader assumes.

# What is built

**Categories, alphabetised within.** The grid is drawn by `ACTION_SECTIONS`:

| Category | Actions (as labelled) |
| --- | --- |
| Content | Authoring briefs (write); Content (pages); Forms; Navigation; Read form submissions |
| Appearance | Layouts; Themes |
| Data | Data rows (named tables only); Data tables |
| Site | Domains & site packages; Services (WebDAV/MCP/OAuth switches); Site config (+ plugins) |
| Accounts | Create sub-users; Delegate sub-users; Users & groups |
| Operations | Housekeeping; Purge; Run scheduled jobs |
| Insight | Agent feedback; Analytics; Audit trail; Notifications |

Rows sort by their label at render time, since the label is what the reader
scans (the key is on hover, SM617). Channels sort the same way. `ACTIONS`
stays the flat registry that `t/lint/19` reads for parity with `@CAP_KEYS`;
the same lint now holds that `ACTION_SECTIONS` names exactly those keys, once
each. If a key ever escapes the sections it is drawn under **Other** rather
than dropped - a grant that is not drawn cannot be seen, audited or revoked,
which is the shape SM439, SM615 and SM668 each closed.

**The unit on the field.** `daemon_tick_seconds` is labelled "Seconds between
the scheduler's checks for due work" and its note says "wakes every this many
seconds".

# Not done

The Users page's read-only grid (`permissions-grid`) lists actions in the
engine's order down a channel table. It answers a different question - which
channel reaches which grant for one user - and was not raised; if the same
reading problem appears there, the sections above are the ones to reuse.
