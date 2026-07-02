# 0004 - Two-bucket install classification + content provenance stamp

Status: Accepted
Date: 2026-07-02 (retrospective; D021 classification, 0.5.33 preservation fix,
0.5.35 provenance stamp)
Tags: install, upgrade, classification, provenance

## Context

Upgrading in place must refresh the application without ever destroying
operator content. The homepage-overwrite incident (fixed 0.5.33) showed the
failure mode: a seed file on disk but untracked in the install state was
treated as new and overwritten with boilerplate.

## Decision

1. Every file in a release is classified by `dist/config/classification.json`
   into **code** (always refreshed on upgrade; must match the shipped build)
   or **seed** (operator-editable; overwritten only when the on-disk checksum
   matches the checksum recorded at the previous install). The manifest build
   REFUSES any file matching no rule - unclassified files are unshippable.
2. An untracked-but-present non-code file is PRESERVED and adopted into the
   state, never overwritten (0.5.33).
3. Shipped seed pages carry `provenance: lazysite-starter` front matter, so
   "is this content ours?" is answerable without the state file
   (`lazysite-check.pl` reports lazysite-unmodified / lazysite-customised /
   operator-authored).

## Rationale

Checksum-vs-recorded distinguishes "edited" from "unmodified"; the provenance
stamp adds identity that survives state loss and separates "operator edited
our page" from "operator's own page". The match-everything manifest rule turns
"file forgotten by packaging" into a build failure instead of a silent gap.

## Consequences

- Upgrades never destroy content; unedited boilerplate refreshes; edited
  or adopted files persist (`install.pl --dry-run` previews the plan).
- Adding any new repo path requires a classification entry (tests fail
  otherwise - by design).
- The stamp is forward-looking: pages authored before 0.5.35 are protected by
  the state rules alone.
