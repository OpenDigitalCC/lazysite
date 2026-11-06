---
id: SM1353
title: "SM1353: more than one manager interface, chosen by group"
subtitle: "The full manager serves a sysop. An owner who only switches what is available and changes their hours needs a far smaller one. The engine should accommodate several manager interfaces over one API, chosen per group."
brand: plain
standard-margins: true
status: candidate
raised: 2026-11-06
raised-by: "release manager (SM1350 discussion)"
area: manager
status-note: "Filed 2026-11-06 under SM1350. The simple manager's task list is open and will be developed as it becomes clear."
---

# Proposed

- **Interfaces are registered:** a manager interface is a set of pages that call the existing manager API. Today's manager is one, named `full`. Others are installed like a layout or an extension and registered by name.
- **Chosen by group:** a group may set `manager: <name>`. A member sees that interface at `/manager/`. If an account is in several groups that name different interfaces, the full one wins only for operators; otherwise it is the first in group order. The account page shows which one applies.
- **The same permissions underneath:** an interface hides tasks; it never widens access. The API refuses what the account cannot do, whichever interface asked.
- **The full manager stays reachable** to anyone allowed it, via `/manager/?interface=full`.
- **The interface contract:** a small documented set covering:
  - the pages it serves;
  - the API actions it uses, checked by a lint against the API;
  - the strings it needs.

  Each interface is tested against the API, like the full manager.

# The simple manager: what it should provide (open list)

- **Switch items on and off:** mark items available or sold out, with one tap each (SM1355).
- **Change opening hours and closures** (SM1356).
- **Send a photo update, and see its preview and publish it** (SM1359, SM1354).
- **Undo the last publish** (content history).
- **Talk to the agent:** the client room (SM1360).
- **Change contact details** shown on the site.
- **Account:** passkeys, sign-out.

Not in it: layouts, themes, permissions, handlers or raw files.

# Questions for ruling

1. Should an interface be allowed to be an app's own code, or only pages over the API?
