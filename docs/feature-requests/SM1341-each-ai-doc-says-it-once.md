---
id: SM1341
title: "SM1341: each AI doc says it once, and says who it is for"
subtitle: "The shipped AI docs gave the connect steps on two pages, authentication, endpoints and the grant model on two, and the layouts machinery on two that did not link each other; only the briefings said who they were for. Each topic now has one home the others point at, every page opens with Who this is for, and the docs index is by reader."
brand: plain
standard-margins: true
status: shipped
raised: 2026-11-05
raised-by: "the lazysite.io site agent (inbox 2026-11-05, the AI docs say the setup three times; review REVIEW-ai-docs-2026-11-05); ruling 80"
area: docs
status-note: "SHIPPED (PENDING) on n749: docs only. t/lint/311 pins the one homes; t/lint/274 D-4 reads the connect code's life from its new home."
---

# What was asked

Ruling 80 (2026-11-05, Q12, triage T-42): no separate knowledge base. The AI docs get
one source per topic: the connect steps in ai-connector-setup; authentication,
endpoints and the connection model in ai-connector-tools; the layouts machinery split
by reader with a link each way. Every page opens with "Who this is for", and the docs
index is arranged by reader, then theme. A docs-only branch.

The owner followed the site's guide through its links and met the setup three times.
The review counted 8,400 words between the publishing briefing and the tools reference,
both holding authentication, endpoints, connection modes and the denied-path model.

# What shipped

All under `starter/lazysite/templates/docs/` (the engine-served manual, SM1284).

Connect steps
: `onboard-ai-agent` step 3 no longer repeats the Claude.ai, ChatGPT and token
  paragraphs; it links `ai-connector-setup`, the one page with each client's steps.
  The two facts only Onboard had moved there: check that WebDAV is enabled, and the
  connect code lasts 30 minutes (in its troubleshooting). Setup's own "two ways to
  authenticate" block is one paragraph pointing at the tools reference's
  Authentication; its "No token is ever pasted into chat" and "the token comes from
  Generate agent brief" moved into that section.

Authentication, endpoints, connection modes, the grant model
: `ai-briefing-publishing`'s Authentication (the pairing-key exchange, Basic auth,
  rotate, recover, the curl examples, checking access and the grant), Endpoints,
  Connection modes and Scope and denied paths moved into `ai-connector-tools`, merged
  with its Endpoint and protocol, Authentication and What is walled off (now a
  subsection of Scope and denied paths). The publishing briefing keeps a short
  section linking each of the five. "Capabilities are read from your account on every
  request" is said once, in Capabilities; the publishing briefing's "Themes and
  layouts have their own gates" is a pointer to the layouts briefing's staging and
  read-only sections, which held every step it gave.

Layouts, by reader
: `layouts` is the person's page and the model: the definitions, the on-disk tree
  (moved from the briefing), resolution (with the `[A-Za-z0-9_-]` rule and what
  renders when a theme does not declare the layout, both moved from the briefing),
  installing, switching and asset paths. Its minimum `layout.tt` was a shorter copy of
  the briefing's and is now a link to it. `ai-briefing-layouts` is the agent's: it
  opens by pointing at `layouts` for the model, and each page links the other.

Who this is for
: Every page of the set opens with it: the index, onboard-ai-agent,
  ai-connector-setup, ai-connector-tools, layouts, the briefings and the two
  integrations pages. The field-practice briefing is generated (lint 89) and opens
  with "What this is, and what it is not"; it is left as it is.

The index
: By reader, then theme: the operator (giving an assistant access, installing and
  configuring, accounts, content, look, forms and data), an AI agent (connecting,
  building and writing, look, configuration and data, outside sources), a developer.
  Every page it listed is still listed; it adds integrations, integrations/figma, the
  field-practice briefing and development. The "Connecting an assistant" paraphrase is
  gone.

Examples
: The moved partner-id example `claude-dhcf` is `claude-example`; the bundle example's
  layout and the layouts pages' theme examples name `mysite` and `mytheme`.

# Word counts

| Page | Before | After |
|---|---:|---:|
| index | 556 | 748 |
| onboard-ai-agent | 728 | 594 |
| ai-connector-setup | 1,038 | 1,042 |
| ai-connector-tools | 3,705 | 4,663 |
| ai-briefing-publishing | 4,779 | 3,963 |
| ai-briefing-layouts | 4,295 | 4,294 |
| layouts | 663 | 862 |

The publishing briefing and the tools reference hold 8,626 words between them, against
8,484: every fact moved, none dropped, and the difference is the two openings and the
pointers. (Counts include SM1340's line and SM1342's anchor fixes.)

# Tests

- **t/lint/311** (new): the client menus (`Add custom connector`, `Developer mode`,
  `CIMD`) are on ai-connector-setup only, and Onboard links it; `action=exchange` is in
  the tools reference only (and the onboarding-brief template, which is the brief);
  Connection modes has one home; the publishing briefing has none of the five sections
  and links each in the tools reference; the layouts pages link each other and there is
  one minimum `layout.tt`; the index has the three reader sections and lists
  integrations/figma; every page of the set opens with Who this is for.
- **t/lint/274** D-4 reads the connect code's 30 minutes from ai-connector-setup.

Run against the base's docs, the lint fails 24 assertions in all five of its subtests:
two client menus on two pages and Onboard naming them, eleven on where authentication,
endpoints and connection modes live, the two cross-links, the index's readers and
Figma, and the five pages without the opening.

# Open

- `ai-connector-tools` is `auth: required` (SM993, ruled 2026-10-12), and
  `ai-briefing-publishing` is public. The pairing-key exchange and the rest now live
  on the signed-in page. The onboarding brief still carries the exchange and rotate
  calls, so an agent is not left without them, but a reader who is not signed in sees
  the publishing briefing's pointers and not their target. To rule: make the tools
  reference public, or keep it signed-in.
