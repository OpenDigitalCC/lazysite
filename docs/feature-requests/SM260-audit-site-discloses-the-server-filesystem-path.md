---
title: "SM260 - audit_site returned the server filesystem path, and its stale-HTML scan never ran"
subtitle: "One list-assignment mistake did both: the docroot was reported to every partner as a finding, and the walk it was supposed to start was never entered."
brand: plain
status: candidate
status-note: "Reported by the site agent 2026-08-08 testing 0.10.3 on edge.explore.lazysite.io over MCP, with the operator's knowledge. Root cause found to be `my ( @stale, @stack ) = ( (), $DOCROOT );` - the first array slurps the whole right-hand side, so @stale started holding the docroot and @stack was empty. The reporter identified the disclosure; the dead feature underneath it was found while fixing. FIXED with t/integration/33 as a standing sweep of the read-only partner surface."
---

# SM260 - the audit disclosed the docroot, and never audited

## What was returned

`audit_site` returned, to any token or MCP client:

```json
"stale_html": ["/home/ispadmin/web/edge.explore.lazysite.io/public_html"]
```

Every other field in the same response is site-relative: `starter_pages` lists
`/contact` and `/index`, `pages` is a count. This one was an absolute server
path including the hosting account name.

## Why it matters

It contradicts a position the platform states in its own `.well-known/ai-partner`,
where analytics is described as

> sanitised + IP-anonymised, never the raw log or **a path**

A partner grant is deliberately a lesser thing than shell access. The docroot
tells the holder the hosting layout and the account name, and on shared hosting
the account name is the more useful half. Neither is needed by any content
operation.

It also travels further than an API response. An MCP client is frequently a
conversational assistant, so the value lands in a transcript held by a third
party - the same reasoning that keeps pairing keys out of connector
conversations.

## Root cause - one line, two defects

```perl
my ( @stale, @stack ) = ( (), $DOCROOT );
```

This does not do what it reads like. In a list assignment the FIRST array
consumes every remaining value, so:

- `@stale` began as `($DOCROOT)` - the disclosure, present in every response
  before the scan could have added anything;
- `@stack` began EMPTY, so the `while (@stack)` walk below was never entered.

So the stale-HTML audit has never worked. It reported exactly one finding, always
the same one, and that finding was the path it was supposed to start walking
from. A reader of the output would reasonably conclude the site had one stale
file at its docroot.

Same family as the `sort SUBNAME LIST` trap recorded earlier in this codebase:
valid Perl that parses as something other than it reads as, with no warning.

## The fix

Declare the two separately, so the shape cannot mislead again:

```perl
my @stale;
my @stack = ($DOCROOT);
```

The existing relativiser inside the loop (`s{^\Q$DOCROOT\E/+}{/}`) was always
correct - it simply never ran.

## The guard

`t/integration/33-no-filesystem-paths-to-partners.t` sweeps the read-only partner
surface - fourteen tools including `audit_site`, `describe_capabilities`,
`whoami`, `list_files`, `read_page`, `validate_page`, `search_files` - and
asserts that no response body carries an absolute filesystem path, wherever it
is nested and however it is reached. It checks the raw JSON, so a path inside an
array, a message or an error is caught too.

The fixture's docroot is deliberately distinctive
(`<tmp>/hostingacct/web/example.test/public_html`) so a leak cannot hide in a
common word, and the account-name segment is asserted separately because a
partial path is still a disclosure.

Verified to FAIL against the original code (6 failures, including the dead scan)
before the fix, so it is a real guard rather than a test shaped to pass.

A sweep rather than an assertion on one field, deliberately: this leak was in a
field nobody was watching, and the next one will be somewhere else.

## Follow-on worth considering

The sweep covers the read-only surface. The write surface returns paths in
success and error messages too, and an error path is exactly where an unsanitised
`$!` or `$@` tends to carry a full filename. Extending the sweep to write
responses, and to the control API alongside MCP, would be the natural next step -
filed here as a note rather than a separate SM until someone judges the cost.
