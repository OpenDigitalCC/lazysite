---
title: "SM254 - Guard the documentation against dead paths, and correct the drift a machine can find"
subtitle: "A docs audit found fourteen divergences between the documentation and the engine. This closes the four that are mechanically checkable and builds the lint that stops them recurring. The remaining ten are SM263."
brand: plain
status: shipped
status-note: "IMPLEMENTED in the 0.10.4 line (2026-08-08). SCOPE DELIBERATELY NARROWED from the original filing: this request now covers only the lint and the four corrections a machine can verify, and the ten judgement-call items were moved to SM263 rather than left inside a 'partial'. The operator's reasoning, and it is right: a partial forces a later reader to pick through the doc working out what was and was not done, when two clean records cost nothing. Original filing from a docs-audit note of 2026-07-26, produced by source-validating every claim while rewriting the public site; never actioned, found and filed 2026-08-08."
---

# SM254 - guard the docs against dead paths

## Why

A docs audit against the v0.9.15 tree found fourteen places where the
documentation and the code disagree. None dangerous. Together they matter,
because documentation that is wrong in fourteen small ways cannot be relied on
without opening the source - which is precisely the work it exists to save.

Four of the fourteen are mechanically checkable. Those are this request. The
other ten are judgement calls and two open decisions, and they are **SM263**.

## What shipped

### The guard

`t/lint/27-docs-reference-real-paths.t` fails when the documentation names a path
or a shell script the tree does not contain. Both dead paths below would have
failed it the day they were removed.

It is **deliberately narrow**, because a lint that cries wolf gets switched off:

- only repo-relative paths (`tools/`, `lib/`, `plugins/`, `debian/`, `starter/`,
  `installers/`) and bare `.sh` names;
- only tokens that LOOK like a file - an extension, or a trailing slash. Without
  that it fires on `tools/list` and `tools/call`, which are JSON-RPC method
  names, and on "plugins / handlers / form-targets", which is a sentence;
- **not the CHANGELOG**, which correctly names files that existed when an old
  release shipped. Rewriting history to satisfy a lint would be the wrong repair;
- exceptions carry their REASON in the exempt list. An unexplained exemption is
  how a lint stops meaning anything.

`t/lint/01-stale-paths.t` is not this: it greps a hand-listed set of files for one
literal left behind by the D013 rename.

**It found four references the audit had not listed.** Three were legitimate - a
one-off disaster-rehearsal script kept in session records, two scripts named as
what `tools/release.sh` replaced, and an example script the reader writes
themselves - and are exempted with those reasons. The fourth was a stale
`registries/` entry in a repository-structure listing, corrected below.

### The corrections

| Was | Now |
|---|---|
| `starter/registries/*.tt` | `starter/lazysite/templates/registries/*.tt`, where they actually ship |
| `uninstall.sh` (two docs, plus a tree listing) | Removed. It does not exist and never did - there is no uninstall mechanism anywhere in the tree |
| `DEVELOPER.md`: "≈2,700 tests" | Removed, not updated - the doc points at the `Files=… Tests=…` line the run prints |
| `FEATURES.md`: 147x cache-hit speedup | 155x, self-evident from the doc's own figures since 62.2 / 0.4 is 155.5 |

Two of those deserve a note.

**`uninstall.sh`** was promised by two documents and has never existed. The
install doc now describes manual removal honestly - delete the engine scripts the
installer placed in `cgi-bin/`, restore the previous web-server config - and says
plainly that a domain's `public_html` is not touched, which is the question
anyone reading an uninstall section actually has.

**The test count** was removed rather than corrected. A number nobody maintains
is worse than no number: it is authoritative-looking and wrong, and the next
person to update it will be the first. The run prints its own totals.

## What is NOT here

Everything requiring judgement, moved to **SM263**: the remaining
feature-description and spec-versus-shipped rows, all three "true but reads
wrong" rows, the site-package warts, and the two behaviour questions
(theme-name collision, packaged-install channel default) that need an operator
decision rather than a correction.

## Verification

- The lint passes, and fails when a dead path is introduced.
- The four corrections are in the tree.
- `prove -lr t/lint` green.
