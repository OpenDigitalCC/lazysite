---
title: Onboard an AI agent
subtitle: Give an AI assistant a scoped account to manage your site - in a few steps, fully under your control.
register:
  - sitemap.xml
---

## Who this is for

The operator: the person who runs this site and is giving an AI assistant an
account of its own. The assistant's side - what it reads once it is connected -
is in the briefings, starting with
[AI briefing - building sites](/docs/ai-briefing-building-sites).

lazysite lets an AI assistant - Claude, ChatGPT, Claude Code, or any MCP client - manage your site through exactly the same rules a person follows. You create a dedicated account for it, grant only the permissions you want, connect the assistant, and revoke or expire access whenever you like. Here is the whole flow.

## 1. Add a user for the agent

In the manager, open **Users** and add a new user **under your account**:

- Choose the **AI agent** type.
- Give it a **distinct name** so you can recognise it later - for example `chatgpt-web` or `claude-code`.
- **Do not assign any groups** - the agent gets only the specific permissions you choose in the next step.
- Create it under you, and **Add**.

## 2. Choose its permissions

Find the new user under your username and **expand its panel**. Tick only the permissions you want it to have:

- **Manage content** - create and edit pages.
- **Manage forms** - build forms and bind them to delivery.
- **Manage themes** - change the site's appearance.
- **Manage layouts** - change the site's structure.
- **WebDAV** - direct file access, useful for **Claude Code** and other agentic tools. *(WebDAV must be enabled first, in **Site settings**.)*

Grant the least it needs for the job - you can change this at any time (see step 6).

## 3. Connect the assistant

Open **Connect an AI assistant** for this user, then follow
[Connect an AI assistant](/docs/ai-connector-setup) for the client you use -
Claude.ai, ChatGPT, Claude Desktop, Claude Code, a script or any other MCP
client. That page has the address to enter, the steps for each client, and what
to check when a connection fails.

## 4. Put it to work

Once connected, just ask. Depending on the permissions you granted, your AI can:

- **Create or edit content** - "draft a page about X and publish it".
- **Change the appearance** - "install the *clarity* theme" (a theme).
- **Change the structure** - "switch to a layout with a sidebar" (a layout).
- **Analyse visitor trends** - "how is traffic trending; which pages are growing; is AI-assistant traffic rising" (needs the *analytics* permission; the AI sees aggregated, IP-anonymised figures and the visits per signed-in account name, never the raw log).
- **Build from a design** - connect the Figma MCP server alongside and see [/docs/integrations/figma](/docs/integrations/figma).

## 5. Time-box it (optional)

Set the account to **auto-expire** so access is removed automatically once the work is done - handy for a one-off task.

## 6. Watch, tighten, and revoke

You stay in control the whole time:

- **Did it connect?** Check the **audit log** - every connection and change is recorded, with who did what and when.
- **Remove permissions at any time.** Once a theme or layout has been built, untick that permission and you know the agent can make no further changes of that kind.
- **Disable the account** whenever you want to cut access entirely.

Grant narrowly, watch the audit log, and tighten or expire access as soon as the job is done.
