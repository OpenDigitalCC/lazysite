---
id: SM882
title: "SM882: is a fully gated content root a supported configuration?"
subtitle: "SM852's S9 - the per-content-root theme mirror recreates a fully gated content root - cannot be fixed until the question under it is answered. The filing already said so: 'Whether a fully gated content root is a supported configuration is open.' This splits the question out so it can be decided on its own rather than blocking a patch."
brand: plain
standard-margins: true
status: candidate
status-note: "DEFERRED 2026-09-14 by the release manager - 'needs some thought, file and defer to further discussion and decision'. Split out of SM852 (S9), which was graded from reading and NOT reproduced. The behaviour and the fix both depend on a product ruling that has never been made: a content root every page of which is protected is a site that serves nothing anonymously, and it is not clear whether that is a configuration lazysite means to support or an accident an operator can arrive at. Deciding it settles S9, narrows SM881 (the git-sync pull), and tells lazysite-check whether such a root is a state worth reporting."
---

# The row this came from

SM852, S9: *"the per-content-root theme mirror recreates a fully gated content
root. Whether a fully gated content root is a supported configuration is open."*

The mirror writes a domain's theme assets into its content root. If every page
of that root is protected, the root exists only in the private store — and the
mirror recreates it publicly to put the CSS somewhere servable.

# Why it is a question and not a defect

A content root with *some* protected folders is ordinary and well supported. A
content root where **everything** is protected is different in kind: the domain
serves nothing to an anonymous visitor, and the only traffic it can answer is
authenticated.

Two readings, and the code does not choose between them:

- **Supported.** A private site — a client portal, an internal handbook — is a
  reasonable thing to build, and the theme assets have to be served for the
  authenticated pages to look right. The mirror is then correct to create a
  public directory for CSS, and S9 is not a defect at all.
- **Not supported.** Then the mirror is quietly producing a public directory
  under a root the operator believes is entirely private, and the fix is to
  refuse the configuration, or to serve those assets from somewhere that is not
  inside the gated root.

The same evidence reads as correct behaviour or as an exposure depending on
which answer is intended. That is the definition of a question that has to be
decided before it can be built.

# What the answer settles

- **S9 itself** — defect, or documented behaviour.
- **[[SM881]]** — a pull into a fully gated root is the sharpest case of the
  same exposure, and how much it matters depends on whether such a root is
  meant to exist.
- **`lazysite check`** — if it is unsupported, a fully gated content root is a
  state worth reporting to the operator, and nothing reports it now.
- **The theme mirror's contract** — whether "assets live in the content root" is
  unconditional, or has an exception.

# Not reproduced

SM852 graded this row from reading and so is this filing. The purge and the seed
rows from the same list both reproduced exactly as written, so the reading is
likely right — but nobody has yet stood a fully gated content root up and
watched the mirror run, and that should happen before anything is built either
way.

# Related

[[SM852]] (this was its S9), [[SM881]], [[SM286]], [[SM438]].
