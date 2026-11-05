---
title: Documentation
subtitle: Everything this site publishes about how lazysite works, and which question each page answers.
register:
  - sitemap.xml
---

## Who this is for

Anyone who runs a lazysite site, an AI agent working on one, or someone working
on the engine itself. The pages are grouped by who reads them, then by theme:
start in your own section.

This manual is the engine's. It serves on every site, upgrades refresh it, and a
page the site puts at the same path overrides it - see
[The /docs manual](/docs/configuration#thedocsmanual).

## Setting up and running a site: the operator

### Giving an AI assistant access

[Onboard an AI agent](/docs/onboard-ai-agent)
: The operator's side of granting a partner access: the account, its
permissions, and watching and revoking it.

[Connect an AI assistant](/docs/ai-connector-setup)
: Adding the site to Claude.ai, ChatGPT, Claude Desktop, Claude Code or another
MCP client, step by step.

### Installing and configuring

[Installation](/docs/install)
: Installing and upgrading.

[Configuration](/docs/configuration)
: `lazysite.conf`, nav and extensions.

[Manager](/docs/manager)
: The manager interface.

[Reference](/docs/reference)
: Keys, variables and file locations.

[Troubleshooting and migrating](/docs/troubleshooting)
: When something does not behave.

### Accounts and access

[Authentication](/docs/auth)
: Accounts, groups, capabilities and the access model.

[Behind an identity provider](/docs/behind-an-identity-provider)
: Letting a proxy in front of the site sign visitors in, what the provider's groups may do, and a Caddy and Authentik example.

### Content

[Authoring](/docs/authoring)
: Writing content.

[Front matter](/docs/frontmatter)
: Every front-matter key a page may carry.

[Advanced authoring](/docs/features)
: The richer authoring constructs.

[Remote content](/docs/remote-content)
: Pulling content from elsewhere.

[API and raw mode](/docs/api)
: The control API, and serving a page as an artifact rather than a document.

### Look

[Layouts and themes](/docs/layouts)
: How layouts and themes are structured.

### Forms, data and connections

[Forms](/docs/forms)
: Defining forms, field types, validation, limits, and reading what they collect.

[Form helpers](/docs/forms-helpers)
: The delivery handlers a form can bind to.

[SMTP configuration](/docs/forms-smtp)
: Mail delivery for forms.

[Data tables](/docs/data-tables)
: Declaring a table, putting records in it, and reading them on a page.

[Connectors](/docs/connectors)
: A credentialed destination forms and callers send site data through, and where the answer is kept.

[The Odoo extension](/docs/odoo)
: Running named Odoo operations from pages, forms, the schedule and agents, and what bounds each.

[Payment](/docs/payment)
: The x402 payment flow.

[Installing a site as an app](/docs/app)
: Making a site, or one section of it, installable on a phone as a progressive web app, and what the device keeps.

## Working on a site: an AI agent

If you are an AI partner connecting over MCP or the control API, read the
briefings first. They are written for you, and they answer most of what the tool
surface alone will not. The operator's pages above are the reference behind them.

### Connecting

[AI connector - tools reference](/docs/ai-connector-tools)
: Endpoints, connection modes, authentication, capabilities and denied paths,
and every tool the connector exposes.

[AI briefing - publishing](/docs/ai-briefing-publishing)
: The onboarding brief, the path mapping, WebDAV, the control API actions,
briefs, ownership and cache behaviour.

### Building and writing

[AI briefing - building sites](/docs/ai-briefing-building-sites)
: Read before creating or restructuring pages. How content, layout and theme stay
separate, and what not to do.

[AI briefing - content authoring](/docs/ai-briefing-authoring)
: Front matter, Markdown, URLs, and the content rules.

[AI briefing - field practice](/docs/ai-briefing-practice)
: One agent's field notes from real sites, a companion to the briefings.

### Look

[AI briefing - layouts and themes](/docs/ai-briefing-layouts)
: Layouts, themes, and the token vocabulary.

### Configuration and data

[AI briefing - configuration](/docs/ai-briefing-configuration)
: Site configuration keys and what they change.

[AI briefing - data tables](/docs/ai-briefing-data)
: Declaring tables, loading records, and rendering them - for an assistant.

[AI briefing - visitor analytics](/docs/ai-briefing-stats)
: How to read the analytics payload and answer questions about traffic.

### Bringing in an outside source

[Integrations](/docs/integrations)
: How an agent brings an external design, document or export into a site.

[Figma](/docs/integrations/figma)
: Building or restyling a site from a Figma design.

## Working on the engine: a developer

[AI briefing - development](/docs/ai-briefing-development)
: Working on the engine itself.

[Development](/docs/development)
: The local development server, build tools, and troubleshooting.

## A note on capabilities

A capability map answers *what has this account been granted*. It does not answer
*what can lazysite do* - these pages answer that. If a tool is not offered to you,
the usual reason is that the capability has not been granted, not that the feature
does not exist. Ask the operator.
