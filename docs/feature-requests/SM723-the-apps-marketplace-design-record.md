---
id: SM723
title: "SM723: the apps marketplace - design record"
subtitle: "What was worked out before building began. The marketplace is NOT being built yet: this document exists so the decisions survive until it is, and so the core portability work leaves the right slots open. Nothing here is implementation instruction; where the core briefing and this document touch, the core briefing wins."
brand: plain
standard-margins: true
status: candidate
status-note: "Documented 31/08/2026 from design discussion with the operator. DO NOT BUILD. Sequencing decided: the marketplace is initially just a git repo proving the round trip with internal-team apps only; the packaging functions come from that exercise (see the core briefing); the external marketplace is a later development and will likely itself be a lazysite app. Every schema slot this document names must exist in the core manifest from day one, unpopulated - retrofitting a required declaration onto a live population is the failure this document exists to prevent."
---

# Where this sits - read this first

**DO NOT BUILD.** This is a design record, preserved so the decisions survive
until the marketplace is wanted. It is not implementation instruction, and
where it and the core portability phases touch, **the phases win.**

The core portability work is SM715 to SM722, sequenced in
`docs/plans/apps-portability-workplan.md`. This document becomes buildable only
after SM722 - the round trip - has proved apps are portable at all.

**The one obligation this document places on the phases now**: every schema
slot named here must exist in the core manifest (SM715) from day one,
unpopulated. Retrofitting a required declaration onto a live population is the
failure this document exists to prevent, and it is the reason the marketplace
was designed before it was wanted rather than after.

The text below is the design discussion of 2026-08-31, unchanged.

# Positioning

The catalogue is open source only: redistributable, forkable apps with the
source present and readable. Money reaches authors through donations and
services, never through gated artefacts. Open Digital does not process
payments. The commercial proposition remains standing behind the software,
and the strongest commercial hook is the private catalogue - an agency with
its own app repo has a platform reason to stay that is independent of the
core being free.

The core is MIT for this project. Apps are independent works; authors choose
their own terms within the admission rules below.

# Architecture

Federated. A catalogue is a repo; the instance is configured with one or
more catalogue repos, exactly as layouts work today. Open Digital's
catalogue is one among peers, which also keeps Open Digital a publisher of
pointers rather than a distributor of other people's products - the
CRA-relevant distinction. A hosted catalogue remains a later commercial
option; nothing in the design requires it.

The remote is git throughout, disguised as manager UI. Publish, fetch,
update and (later) contribution all ride the same mechanics.
`plugins/git-sync.pl` should be evaluated as the transport before anything
new is written.

# Admission rules

Open licence
: OSI-approved terms, recorded as an SPDX identifier. Non-redistributable
  works are not admitted; funding is voluntary by construction.

Source present
: No precompiled artefacts, no minified or obfuscated bundles, no
  install-time fetch of code from elsewhere. Everything an app contains is
  readable at the pinned commit by the operator, their agent and any
  scanner. This single rule does more for supply-chain safety than any
  review process.

Pinned provenance
: Catalogue entries point at a tag and commit hash, never a branch. What
  was reviewed is what installs.

Automated scan
: A lint at admission: no undeclared fetch targets in JavaScript, no
  minification, descriptor validation passes, reserved seed columns
  present, and catalogue text that reads as instruction to an AI assistant
  flagged for rejection - descriptions and READMEs are attacker-controlled
  text that will land in an installing agent's context.

# Identity and trust

Publisher identity
: No anonymous publishing. A verifiable identity per publisher; apps may be
  namespaced under the publisher (deferred decision - does not alter the
  core design). Namespaces are never transferred and never reused, so an
  abandoned app cannot be revived by whoever acquires an account.

Signing, trust on first use
: The catalogue records a publisher's signing key at first appearance. A
  key change forces re-approval. This is the control that catches
  repository takeover, which is the realistic compromise route.

Channels
: The existing ladder - edge, beta, stable, certified - applies to apps
  unchanged, with an instance setting the minimum maturity it accepts.
  Certified means the review was walked. The ladder gates which
  capabilities an app of that tier may request.

# The update is the attack

Almost no one ships a malicious first version; they ship something useful
and poison a later release, or their account does it for them. Three
mechanical controls:

- updates are never silent - version pinning with explicit operator action
- every update presents a capability diff: a new role, a new path request,
  a new connector shape or domain is the thing being approved, not a line
  in a changelog
- pinned, readable source makes an agent-performed diff review possible in
  a way binary ecosystems cannot offer

# Deprecation, advisories, adoption

Deprecation
: The author stops maintaining. Installed copies keep running; no updates.
  Never delisting.

Advisories
: A separate channel for a specific bad version - security or otherwise.
  The catalogue records it, the manager surfaces it against installed
  copies, the operator decides. Nothing is removed remotely. Minimum
  viable model: each catalogue operator publishes advisories for its own
  catalogue. Who else may file one is an open question.

Adoption
: A deprecated app may be continued by fork under the new maintainer's
  namespace, subject to licence. The catalogue entry gains a successor
  pointer - set by the author while reachable, by the catalogue operator
  otherwise. Funding pointers follow the maintainer; upstream remains as
  credit in ancestry.

# Licence schema

Authors are not lawyers; free-text licence fields produce a catalogue
nobody can compute over. Authors answer intent questions - may others
redistribute, may they modify, must modifications be published, may it be
combined with other terms - and the schema derives the licence, stored as
SPDX underneath. Since only open licences are admitted, the derivation
space is small: permissive, weak copyleft, strong copyleft.

Two grants are stated separately, because a code licence does not cover the
second:

code grant
: The chosen licence. Governs redistribution, modification, merging.

data grant
: Seed schema and data, granted perpetually and irrevocably to the
  installing instance, surviving uninstall, deprecation and any later
  relicensing. Stated once at schema level so a retained table can never
  become retrospectively infringing.

Merging apps is an expected use. The manager checks licence compatibility
at merge time and refuses an unlawful combination with the reason named,
rather than producing a silently unlawful artefact. Ancestry (already in
the core manifest) is what makes attribution automatic and compatibility
checkable.

# Funding

A manifest block, not a payment rail: the author's stated running costs,
and pointers to their own arrangements - subscription link, donation link,
invoice address. Rendered in the app card and the manager. Money never
crosses Open Digital's boundary; hosted payment handling is a possible
later Cloudient service for authors who want it, priced as a service.

Funding pointers follow the maintainer of the installed lineage, not the
ancestry root - anything else creates disputes someone would have to
arbitrate.

# The contribution loop

Fork-with-attribution is the default path and the one expected to carry
traffic. The pull-request loop - fork, modify, propose upstream, author
accepts or rejects, rejected forks proceed under licence - is a forge
client behind lazysite UI and a substantial build; its realistic failure
is social, not technical: most published apps will have a maintainer who
never reviews, and a PR flow that rots discredits itself. Build it after
the population exists and only if upstream contribution is actually
wanted.

The feeder is already in the core design: a diverged install
(operator-modified, taint computed from content history) plus
publish-as-fork produces a new app with recorded ancestry and a clean
change set - which is a mergeable object, where a folder edited for six
months is not.

# Agent surface

Everything the catalogue carries enters an agent's context as data, never
instruction. Search and propose are agent acts; install is a human act
carrying the role mappings, path grants and connector bindings - the
`bind_form` precedent throughout. The admission scan's
instruction-shaped-text check is the catalogue-side half of the same
control.

# What the daemon changes, when it arrives

Today's apps are inert without a visitor. The persistent runtime (SM221
and dependents) introduces execution with no visitor present - timers,
external triggers, held connections - and the workflow engine turns
content into instructions that act. The marketplace's trust model is
designed for that future, not for the inert present: the manifest's
declaration slots for triggers, timers, realtime channels and egress
exist from the first release precisely so the catalogue's controls do not
have to be retrofitted onto a live population when SM221 lands.

# Sequencing, restated

1. Now: core portability (separate briefing). Marketplace is a plain repo;
   internal team publishes by hand; round trip proven on a fresh instance.
2. Then: packaging functions from the round-trip log; publish and install
   through the manager; the repo becomes the internal catalogue.
3. Later, when third parties are wanted: admission scan, publisher
   identity, signing, channels for apps, licence derivation UI, funding
   display, advisories.
4. Later still, if wanted: the contribution loop, hosted catalogue as a
   commercial decision, the external marketplace built as a lazysite app.

# Open questions held for later

- Publisher-prefixed namespace versus flat names in a central register.
- Who may file an advisory besides the catalogue operator.
- Whether the certified rung for apps reuses `lazysite-compliance.pl`
  gates or gets its own register.
- The catalogue's own hosting when a hosted option is commercially
  wanted, and what that does to the distributor position.
