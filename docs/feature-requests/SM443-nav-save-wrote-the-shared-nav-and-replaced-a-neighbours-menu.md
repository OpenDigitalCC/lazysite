---
title: "SM443: a per-domain nav save replaced another site's navigation"
subtitle: "nav-read takes host in the QUERY; nav-save takes it in the BODY. Pass it the way the read wants and the save silently drops it, defaults to the shared nav.conf, and overwrites whatever the primary and every inheriting domain were using."
brand: plain
standard-margins: true
status: candidate
status-note: "PARTIALLY SHIPPED (PENDING): the SECOND half only - a per-domain nav file is now writable over WebDAV, gated on manage_nav, for any path lazysite.conf declares as a nav_file and which has the nav-file shape. THE FIRST HALF IS DELIBERATELY NOT SHIPPED: nav-save still treats an absent host as the shared file, which is the destructive default that replaced a third party's navigation. Refusing there turns a previously-successful call into an error, so it wants an edge soak rather than riding a beta cut - it is held with SM436's matching rejection for the following release. ORIGINAL FILING FOLLOWS. FILED 2026-08-20 from the field after a LIVE CROSS-SITE OVERWRITE. The reporter set the xisl domain's nav_file to lazysite/nav-xisl.conf, confirmed it with nav-read (inherited:0), called nav-save with host=xisl..., got ok - and the NEIGHBOURING site's navigation was replaced. That neighbour is the site handed to another party this morning. They noticed on a hunch, restored it within a couple of minutes and verified the rendered menu. Recorded as what it is. THE MECHANISM IS NOT 'nav-save ignores host', and this matters because it changes the fix. SM318 already unified both surfaces on one host-aware implementation: action_nav_save($items, $host) calls _nav_conf_path($host), and the module header documents the per-domain row as the defect it was written to close. What differs is WHERE THE PARAMETER IS READ FROM. In ControlApi/Actions.pm, nav-read declares host `in => 'query'` and nav-save declares it `in => 'body'`. A caller that passes host consistently - as the read requires - has it silently dropped on the write, $host arrives empty, _nav_conf_path('') resolves to the shared lazysite/nav.conf, and the save lands on the primary's nav and every domain inheriting it. Every observation follows: ok returned, the neighbour's menu replaced, and a later nav-read of the intended host still reporting nav-xisl.conf with items:[] because that file was never written. CONFIRMED 2026-08-20 by the reporter, from the call rather than from memory. The invocation was `lzs-dav.sh api sites.lazysite.io 'action=nav-save&host=xisl.sites.lazysite.io' tmp/xisl-nav.json`, and that helper posts to lazysite-manager-api.pl?action=<the whole string> - so action AND host were both QUERY parameters. They checked the body file's top-level keys rather than trusting recall: ['items'], no host key at all. nav-save declares host in => 'body', the host arrived in the query, $host was empty, _nav_conf_path('') resolved to the shared nav.conf. The mechanism is settled. THE DESIGN DEFECT UNDERNEATH is worth more than the parameter plumbing: an ABSENT host on a destructive write silently means 'the shared file'. That is a destructive default on the one operation that can clobber every domain at once, and the same trap SM436 recorded on domain-add, where parameters read from the body answered a query-string call with 'Invalid domain host'. There the wrong-place parameter produced a confusing error; here it produces silent data loss on somebody else's site. SECOND HALF, CONFIRMED WITH AN EXACT CAUSE, and it may matter more for the fix: there is NO way to create a per-domain nav file from a content grant. nav-save writes the shared file; WebDAV refuses because the carve-out in authorise() is an EXACT STRING MATCH - `if ( $rel eq 'lazysite/nav.conf' )` - so lazysite/nav-xisl.conf is not covered and falls through to the blanket lazysite/ denial. So domain-set will accept a nav_file that can never be populated, and because layouts guard on [% IF nav.size %] the result is a site with NO navigation rather than an error. Broadening that carve-out to the nav_file paths actually configured, still gated on manage_nav, is the obvious remedy. The reporter's workaround is recorded below. THEIR SUGGESTED TEST IS RIGHT AND WORTH STRENGTHENING: set a per-domain nav_file, save that host's nav, assert the base nav.conf is BYTE-UNCHANGED - and assert the per-domain file now EXISTS, since the current failure mode writes the wrong file and creates nothing. A single-domain instance passes either way."
---

# What happened

```datatable
columns: Step | Result
widths: 7cm | X
bold: 1
tone: medium
---
`domain-set` xisl `nav_file` = `lazysite/nav-xisl.conf` | ok
`nav-read` host=xisl | confirms `nav-xisl.conf`, `inherited: 0`
`nav-save` host=xisl | **ok - and the NEIGHBOUR's menu was replaced**
`nav-read` host=xisl afterwards | still `nav-xisl.conf`, `items: []` - never written
```

::: widebox
The two calls disagree about which file they mean, and the caller is told
nothing. The read reports the per-domain file; the write lands on the shared
one.
:::

# Where the two halves diverge

`lib/Lazysite/ControlApi/Actions.pm`:

```perl
'nav-read' => { ... params => [ { name => 'host', in => 'query' } ] },
'nav-save' => { ... params => [ { name => 'items', in => 'body' },
                                { name => 'host',  in => 'body'  } ] },
```

The implementation is host-aware - SM318 unified both surfaces precisely to
close the per-domain row, and `action_nav_save( $items, $host )` calls
`_nav_conf_path($host)`. So a host that ARRIVES is honoured. A host passed the
way the READ requires does not arrive.

`_nav_conf_path('')` is the shared `lazysite/nav.conf`.

**An absent host on a destructive write silently means the shared file.** That
is the defect worth fixing, ahead of the plumbing: it is a destructive default
on the one operation that can affect every domain at once.

# The per-domain nav file cannot be created

`authorise()` in `lazysite-dav.pl`:

```perl
if ( $rel eq 'lazysite/nav.conf' ) {
    return undef if manage_nav_for($user);
```

An exact string match on one filename. `lazysite/nav-xisl.conf` is not covered
and falls to the blanket `lazysite/` denial - *"only lazysite/layouts/ is
writable over WebDAV; the rest of lazysite/ is protected"*.

So `domain-set nav_file` accepts a path that no surface can populate, and
because layouts guard on `[% IF nav.size %]`, the visible result is a site with
**no navigation at all** rather than an error.

Remedy: broaden the carve-out to the `nav_file` paths actually configured,
still gated on `manage_nav`.

# Workaround, staging only

Point the BASE `nav_file` at the target file, `nav-save`, then restore the
base. That writes the per-domain file and leaves the neighbour's alone.

There is a few-second window in which inheriting domains resolve to the wrong
nav, which is why it is staging-only and not a recommendation.

# The test

Set a per-domain `nav_file`, save that host's nav, then assert **both**:

- the base `lazysite/nav.conf` is byte-unchanged;
- the per-domain file now exists.

The second assertion matters because the current failure writes the wrong file
and creates nothing - a test checking only that the right file appeared would
also fail, but a test checking only that the save returned ok would pass. A
single-domain instance passes either way, which is the same blind spot SM440
records.

# Confirmed, and the confirmation that was declined

The reporter established the mechanism from the call itself:

```
lzs-dav.sh api sites.lazysite.io 'action=nav-save&host=xisl.sites.lazysite.io' tmp/xisl-nav.json
```

That helper posts to `lazysite-manager-api.pl?action=<the whole string>`, so
`action` and `host` were both query parameters. The body file's top-level keys,
checked rather than recalled: `['items']`. No host key at all.

::: widebox
**The obvious confirmation - put host in the body and re-save - was deliberately
NOT run**, and the reasoning belongs in the record: the failure mode lands on
the neighbouring site handed to another party this morning, so the downside is
theirs to accept rather than the reporter's. A proven method that touches
nothing shared already exists, so the risky version was not needed to get the
work done.

If the body-host path should be exercised before a fix ships, it should be run
by someone whose OWN site would absorb the miss.
:::

That is the correct call. A confirmation that can only be obtained by risking a
third party's site is not a cheap confirmation, and declining it while saying so
is better practice than running it and reporting success.

# The pattern, now twice in one day

An absent parameter on a destructive write silently meaning "the shared file"
has now cost something twice:

```datatable
columns: Filing | Wrong-place parameter produced
widths: 5cm | X
bold: 1
tone: medium
---
SM436 | `Invalid domain host` - a confusing error, on the caller's own time
SM443 | **a third party's navigation replaced**, with `ok` returned
```

A refusal on an unresolvable or absent host would have turned the second into
the first. That is the fix worth making ahead of the parameter plumbing, and
it generalises past nav: every action that can write a SHARED resource when a
selector is missing wants the same treatment.
