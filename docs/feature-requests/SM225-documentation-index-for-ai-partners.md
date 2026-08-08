---
title: "SM225 - Publish a documentation index to AI partners"
subtitle: "A site ships around thirty documentation pages including seven AI briefings. An MCP partner is told about three of them, and describe_capabilities names none. Make the documentation discoverable from the surface partners actually read."
brand: plain
status: shipped
status-note: "IMPLEMENTED in the 0.10.2 edge line (2026-08-08, commit 1138b6e). Raised 2026-08-06 and marked IMPORTANT by the operator. Root cause of most of SM226-SM230: a partner reasoning carefully from the tool surface alone reinvents documented behaviour and concludes absent features. Implementation targeted for the next release."
---

# SM225 - a documentation index for AI partners

## Why

Every lazysite site publishes its own documentation under `/docs/`. There are
seven briefings written specifically for AI partners, plus reference pages for
forms, the control API, authentication, front matter, configuration and
troubleshooting - around thirty pages in `starter/docs/`.

An MCP partner learns about three of them, from prose in the server instruction
string: `ai-briefing-building-sites`, `ai-briefing-authoring` and
`ai-briefing-layouts`. `describe_capabilities` - the call the tool's own
description tells a partner to make first - returns `channels`, `capabilities`,
`tasks`, `engine_owned` and `holds`, and no pointer to documentation of any
kind.

The cost is measurable. In August 2026 a partner produced a 218-line platform
specification proposing five new deliverables. Two of the three questions it
raised as "only you can answer" had shipped answers, documented on pages the
partner could have fetched anonymously at any time. Several of its proposals
duplicated existing features. The reasoning was sound throughout; the inputs
were incomplete.

A partner that cannot find the documentation does not conclude the documentation
exists elsewhere. It concludes the feature does not exist, and designs around
it.

## What is true today

- `starter/docs/` ships `ai-briefing-{authoring, building-sites, configuration,
  development, layouts, publishing, stats}` plus `forms`, `forms-helpers`,
  `forms-smtp`, `api`, `auth`, `auth-upgrade`, `frontmatter`, `reference`,
  `manager`, `troubleshooting`, `remote-content`, `payment`, `install`,
  `features`, `onboard-ai-agent`, `ai-connector-setup`, `ai-connector-tools`,
  and more.
- Each is served at `/docs/<basename>` as an ordinary public page.
- Individual tool descriptions do cite briefings where directly relevant -
  `analyse_visitors` cites `/docs/ai-briefing-stats`, and the MCP instruction
  string cites three. These are the exceptions.
- `describe_capabilities` has no documentation field.
- `/.well-known/ai-partner` advertises endpoints, not documentation.

## What to build

### 1. A `docs` block in `describe_capabilities`

Add a `docs` key to the map returned by `Lazysite::Capabilities::describe`,
listing each published document with its path and a one-line description of what
question it answers. Group it so a partner can select rather than fetch all
thirty:

```
docs => {
  start_here => [ { path => '/docs/ai-briefing-building-sites', answers => '...' }, ... ],
  reference  => [ { path => '/docs/forms', answers => '...' }, ... ],
}
```

The list should be derived from what the site actually publishes rather than
hard-coded, so a site that has removed or added a doc reports the truth. The
`register:` front-matter key already present on briefing pages is a candidate
source; a directory scan of the docs root is the fallback.

### 2. Amend the tool description

`describe_capabilities` currently ends "Call this first to learn what you may
do." Extend it to say the response includes the documentation index and that the
briefings should be read before designing anything.

### 3. A `/docs/` index page

An ordinary published page listing every document with its one-line purpose, so
a human partner has the same affordance. This also gives the `docs` block a
canonical human-readable counterpart to point at.

### 4. Extend the MCP instruction string

Name the index rather than three individual briefings, so the string stops
needing maintenance every time a doc is added.

## Why this is the important one

SM226, SM227, SM228, SM229 and SM230 are each a specific instance of the same
failure: something true about the platform was not visible where a partner was
looking. They are all worth fixing individually, and they would all have been
less costly if the partner had been able to find the documentation first.

This request does not remove the need for the others - a documentation index
does not help if the document is missing (SM229) or if the tool response is
itself misleading (SM226, SM227). It changes them from the only defence into the
second one.

## Verification

- A partner calling `describe_capabilities` receives a documentation index and
  can fetch every listed path anonymously.
- The index reflects the documents the site actually publishes, verified by a
  test that adds a doc and asserts it appears.
- No capability is required to read the index; documentation discovery must work
  before any grant is resolved, the way `whoami` and `describe_capabilities`
  already do.

## Not in scope

- Rewriting the documents themselves. SM229 covers the one known content gap.
- Serving documentation over MCP as a tool. The pages are public HTTP and a
  partner can already fetch them; the problem is knowing they exist.
