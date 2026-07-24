---
title: AI briefing - integrations
subtitle: How an AI agent brings an external source - a design tool, an editor, a CMS export - into a lazysite site through the sanctioned channels.
register:
  - sitemap.xml
  - llms.txt
---

## Who this is for

An AI agent that has been pointed at something OUTSIDE lazysite - a
Figma design, a document in an editor, an export from another CMS - and
asked to turn it into a lazysite site. An integration briefing is the
method for taking that external source through lazysite's own channels
(the MCP tools, or WebDAV + the control API) so the result lands as
themes, layouts and Markdown pages on the rails - not as a foreign blob
dropped into a static path. It reads the source, translates it into the
engine's separation of concerns, and publishes through the same rules a
person follows.

## Available integrations

- [Figma](/docs/integrations/figma) - build or restyle a site from a
  Figma design. A dual-MCP method: bridge the Figma MCP server (the
  source) and a lazysite connection (the destination) in one session,
  extract the design tokens and structure, and rebuild them as a theme +
  layout.

More arrive as they are verified; each gets a predictable slug at
`/docs/integrations/<tool>`. An integration is documented here only once
its tools are confirmed - this is not a wish-list.

## The governing method

Every integration obeys the same principle: identity transfers as
**design tokens**, structure adapts an existing **layout**, and words
become **Markdown pages** - it is never a single hand-built page. Read
[AI briefing - building sites](/docs/ai-briefing-building-sites) first;
it is the "how to think about a lazysite site" briefing that each
integration here applies to one specific external source.

## Related

- [AI briefing - building sites](/docs/ai-briefing-building-sites)
- [AI briefing - layouts and themes](/docs/ai-briefing-layouts)
- [Onboard an AI agent](/docs/onboard-ai-agent)
