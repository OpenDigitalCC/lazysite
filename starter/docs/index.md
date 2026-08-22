---
title: Documentation
subtitle: Everything this site publishes about how lazysite works, and which question each page answers.
register:
  - sitemap.xml
---

## Start here

If you are an AI partner connecting over MCP or the control API, read the
briefings first. They are written for you, and they answer most of what the tool
surface alone will not.

[AI briefing - building sites](/docs/ai-briefing-building-sites)
: Read before creating or restructuring pages. How content, layout and theme stay
separate, and what not to do.

[AI briefing - content authoring](/docs/ai-briefing-authoring)
: Front matter, Markdown, URLs, and the content rules.

[AI briefing - data tables](/docs/ai-briefing-data)
: Declaring tables, loading records, and rendering them - for an assistant.

[AI briefing - layouts and themes](/docs/ai-briefing-layouts)
: Layouts, themes, and the token vocabulary.

[AI briefing - publishing](/docs/ai-briefing-publishing)
: Connecting, authenticating, the path mapping, scope, WebDAV, the control API
and cache behaviour.

[AI briefing - configuration](/docs/ai-briefing-configuration)
: Site configuration keys and what they change.

[AI briefing - visitor analytics](/docs/ai-briefing-stats)
: How to read the analytics payload and answer questions about traffic.

[AI briefing - development](/docs/ai-briefing-development)
: Working on the engine itself.

## Reference

[Reference](/docs/reference)
: Keys, variables and file locations.

[Front matter](/docs/frontmatter)
: Every front-matter key a page may carry.

[Authoring](/docs/authoring)
: Writing content.

[Advanced authoring](/docs/features)
: The richer authoring constructs.

[Layouts and themes](/docs/layouts)
: How layouts and themes are structured.

[Configuration](/docs/configuration)
: `lazysite.conf`, nav and plugins.

[Data tables](/docs/data-tables)
: Declaring a table, putting records in it, and reading them on a page.

[Forms](/docs/forms)
: Defining forms, field types, validation, limits, and reading what they collect.

[Form helpers](/docs/forms-helpers)
: The delivery handlers a form can bind to.

[SMTP configuration](/docs/forms-smtp)
: Mail delivery for forms.

[Authentication](/docs/auth)
: Accounts, groups, capabilities and the access model.

[API and raw mode](/docs/api)
: The control API, and serving a page as an artifact rather than a document.

[Manager](/docs/manager)
: The manager interface.

[Remote content](/docs/remote-content)
: Pulling content from elsewhere.

[Payment](/docs/payment)
: The x402 payment flow.

[Installation](/docs/install)
: Installing and upgrading.

[Troubleshooting and migrating](/docs/troubleshooting)
: When something does not behave.

## Connecting an assistant

[Connect an AI assistant](/docs/ai-connector-setup)
: Setting up an MCP connection.

[AI connector - tools reference](/docs/ai-connector-tools)
: Every tool the connector exposes.

[Onboard an AI agent](/docs/onboard-ai-agent)
: The operator's side of granting a partner access.

## A note on capabilities

A capability map answers *what has this account been granted*. It does not answer
*what can lazysite do* - these pages answer that. If a tool is not offered to you,
the usual reason is that the capability has not been granted, not that the feature
does not exist. Ask the operator.
