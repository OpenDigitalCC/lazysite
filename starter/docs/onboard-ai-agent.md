---
title: Onboard an AI agent
subtitle: Give an AI assistant a scoped account to manage your site - in a few steps, fully under your control.
register:
  - sitemap.xml
  - llms.txt
---

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

Open **Connect an AI assistant** for this user and pick the option that matches your AI. The endpoint is the same for all clients: `https://YOUR-SITE/cgi-bin/lazysite-mcp.pl`.

**Claude.ai (web / mobile)**
: Keep the Connect panel open. In Claude.ai: **Settings → Connectors → Add custom connector**; enter your site name and the endpoint URL; **Add**. Open a chat, enable the connector, and ask Claude to run `whoami`. When it prompts, paste the **connect code** from the panel. No token is ever pasted into the chat.

**ChatGPT (Plus / Pro / Business / Enterprise)**
: In ChatGPT: **Settings → Apps / Connectors → Advanced → Developer mode → Add custom connector**; enter a name and the endpoint URL (OAuth is discovered automatically); create it; then paste the **connect code**. *Plus/Pro can call read-only tools; Business/Enterprise also get the write tools, with a per-call approval.*

**Claude Code / Claude Desktop / scripts (token)**
: Use **Generate agent brief** (a pairing key) or **Generate credential** (an `lzs_` token). Add the endpoint as a remote MCP server with the header `Authorization: Bearer <user>:<lzs_ token>`. A script can also use the control API and WebDAV directly.

The complete tool list, capability model and error reference is in the [AI connector tools reference](/docs/ai-connector-tools). If a connection fails, check that WebDAV is enabled and that the connect code has not expired (it lasts 15 minutes - reopen the panel for a fresh one).

## 4. Put it to work

Once connected, just ask. Depending on the permissions you granted, your AI can:

- **Create or edit content** - "draft a page about X and publish it".
- **Change the appearance** - "install the *clarity* theme" (a theme).
- **Change the structure** - "switch to a layout with a sidebar" (a layout).

## 5. Time-box it (optional)

Set the account to **auto-expire** so access is removed automatically once the work is done - handy for a one-off task.

## 6. Watch, tighten, and revoke

You stay in control the whole time:

- **Did it connect?** Check the **audit log** - every connection and change is recorded, with who did what and when.
- **Remove permissions at any time.** Once a theme or layout has been built, untick that permission and you know the agent can make no further changes of that kind.
- **Disable the account** whenever you want to cut access entirely.

Grant narrowly, watch the audit log, and tighten or expire access as soon as the job is done.
