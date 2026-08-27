---
title: "SM256 - add_alias reports success and writes no alias when the page has no front matter"
subtitle: "rename_page with add_alias:true returns ok:1 and alias_suggested populated, but a page with no `---` block gets nothing written. The retired URL 404s and the agent has been told the opposite."
brand: plain
status: shipped
status-note: "IMPLEMENTED in the 0.10.4 edge line (2026-08-09, commit 1910088). Found 2026-08-08 while writing behaviour coverage for the 0.10.3 MCP tools (t/unit/mcp/14-new-tool-behaviour.t). Found by ACCIDENT: the first fixture page had no front matter, the assertion failed, and the cause turned out to be the feature rather than the test. Not a regression - the alias-on-rename facility is new in 0.10.3 and shipped with this gap. Same family as SM247, which 0.10.3 fixes: an operation reports success without doing the thing that was asked."
---

# SM256 - add_alias silently skips a page with no front matter

## Why

`rename_page` gained `add_alias` in 0.10.3, because retiring a URL without
aliasing it is the most common avoidable cost of a rename - twenty legacy URLs
were lost on one site and recovered by hand afterwards. The tool reports
`alias_suggested` on every rename and writes the alias when asked.

It writes it only when the successor page already has a front-matter block:

```perl
if ( $a->{add_alias} ) {
    my $rd = action_read( "/$new.md", $user );
    if ( ref $rd eq 'HASH' && $rd->{ok} ) {
        my $c = $rd->{content} // '';
        if ( $c =~ m{\A---\s*\n(.*?)\n---\s*\n}s && index( $1, $alias ) < 0 ) {
            ...
```

A page with no `---` block falls through both conditions. Nothing is written,
nothing is reported, and the result still carries `ok:1` **and**
`alias_suggested` - which reads as "here is the alias, and I have added it".

Front matter is optional in lazysite. A page that is pure Markdown is ordinary,
not malformed, and it is if anything MORE likely to be an old hand-written page -
exactly the kind whose URL has been published for years and matters most when it
moves.

## The shape of the defect

This is the SM247 pattern one release later: the caller asks for something, the
platform cannot do it on this input, and it answers `ok`. An agent acting on that
answer moves on and the retired URL starts 404ing silently. The agent has no way
to know: it asked for the alias and was not refused.

Worth noting because it argues for the fix rather than a warning - a warning is
the right answer when the caller might legitimately want either outcome, and here
there is only one thing the caller can have meant.

## What to do

Create the front-matter block when there is none, rather than skipping:

- No `---` block: prepend `---\naliases:\n  - /old-path\n---\n` to the body.
- An existing block: unchanged (extend `aliases:`, or add the key), including the
  existing idempotence check so a repeated rename does not duplicate an entry.

Either way the result should say what actually happened - an `alias_written`
boolean alongside `alias_suggested`, so the two are not conflated. The current
response cannot distinguish "you asked and I did it" from "you asked and I could
not".

## Tests

- `rename_page` with `add_alias` on a page with NO front matter: the block is
  created, the alias is in it, the body survives intact.
- The same on a page WITH front matter: unchanged from today, and still
  idempotent across a second rename.
- The response distinguishes written from merely suggested, in both cases.
- A rename WITHOUT `add_alias` still writes nothing and still reports the
  suggestion (the deliberate opt-in, pinned in
  `t/unit/mcp/13-write-guardrails.t`).

## Scope

`_rename_page` in `lazysite-mcp.pl`, and whichever control-API action shares the
behaviour - check both surfaces, since 0.10.3's own parity lint exists because
they drift.
