---
title: "Site settings"
brand: plain
---

# Site settings

Governing capability: `manage_config`. This is also the manager's home page.

## The dashboard

Where
: System -> Site settings (or the Lazysite Manager brand link)

Do
: Land on it as an operator, then as a user with one capability.

Expect
: The landing view reflects what the signed-in user can actually do. Areas they
  cannot reach are not offered as dead ends.

Negative
: An account with a valid session but no UI capability must be **refused at
  login with a clear message**, not given a session and an unrenderable manager.

## General settings

Where
: System -> Site settings

Do
: Change the site name and the site address, save, and view the public site.

Expect
: Each key is written to `lazysite.conf` individually and the change is visible
  on the next render. Fields that are edited elsewhere are shown read-only with a
  link to where they live.

Negative
: Saving does not send fields the form did not display - a settings page that
  posts its whole model overwrites things nobody edited.

## Services

Where
: System -> Site settings -> Services

Do
: Read the "held by N groups / M accounts" line under each switch. Turn WebDAV
  off and check the Users permissions grid.

Expect
: Every remote surface is **off by default** and stays off until switched on
  here: WebDAV, MCP, OAuth, the control API and the token exchange. When off, the
  endpoint returns 404 and discloses nothing. The holder counts tell you what
  turning a switch off would strip, and the Users grid then flags those grants
  dormant. The two views are the same fact from opposite ends and must agree.

Negative
: Signed in as an operator with `manage_config` but **not** `manage_users`, the
  counts must be **absent, not zero**. Zero would read as "nothing depends on
  this", which is the opposite of the truth.

## Update channel

Where
: System -> Site settings -> Updates

Do
: Set the channel to `stable` and attempt an out-of-channel upgrade.

Expect
: The ladder is edge < beta < stable, and the setting is the **minimum maturity
  this site accepts**. An out-of-channel release is skipped and the skip is
  logged in the audit trail rather than passing silently.

Negative
: Customer sites should be `stable`. Confirm the note says so where the operator
  is choosing.
