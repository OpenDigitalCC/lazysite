---
title: "Users"
brand: plain
---

# Users

Governing capability: `manage_users`. A delegate holding `create_sub_users`
reaches a subset, and the ceiling on that subset is the most important thing on
this page to test.

## Add and remove an account

Where
: Access -> Users -> Add user

Do
: Add a user with a password, then add one without. Remove each.

Expect
: Both appear in the list. Removal takes the account out of every group it was
  in, and the audit trail records who removed whom.

Negative
: A delegate can only see and act on accounts beneath them in the management
  tree - not the whole roster.

## Capabilities, and where they come from

Where
: Access -> Users -> a user's Permissions grid

Do
: Open the grid for a user in a nested group, and for one in no groups.

Expect
: The grid is capability x channel. Each held capability names **which group
  granted it**, following the nesting closure - a capability conferred by nesting
  shows here, because that is what enforcement acts on. A user in no groups is
  told plainly they hold nothing.

Negative
: A capability granted while its **service** is switched off shows a dormant
  warning: granted, and inert until an admin enables the service. Cross-check it
  against Site settings -> Services, which shows the same fact from the other
  end.

## Connect an AI assistant

Where
: Access -> Users -> a user -> Connect

Do
: Take all three routes: **Claude.ai / ChatGPT (web)**, **Claude Desktop
  (connector)**, and **Claude Code / script**.

Expect
: Web gives a one-time connect code with a live countdown, for pasting at the
  OAuth prompt. Desktop gives a `username:token` credential, shown once. Code
  gives a single-use pairing brief. The page detects the agent connecting and
  reveals the next step.

Negative
: An account that can actually use the interactive manager UI is **not**
  connectable as an agent, and the refusal explains why: a leaked connector on a
  live manager account is the accidental-grant vector. Use a dedicated agent
  account with interactive login disabled.

## Regenerate an expired connect code

Where
: Access -> Users -> a user -> Connect -> Claude.ai / ChatGPT (web)

Do
: Watch the code count down. Let it expire (or shorten the TTL). Press
  **Regenerate**.

Expect
: The remaining life is shown and counts down. On expiry the panel says so
  plainly and strikes the code through. Regenerate swaps in a fresh code **in
  place** - the card does not rebuild and you are not returned to the top of the
  flow - the clock restarts, and the old code stops working at the OAuth prompt.

Negative
: A second Regenerate must not leave the first countdown writing into the panel.

## Credentials and expiry

Where
: Access -> Users -> a user

Do
: Generate a token, set an expiry date, then clear it. Disable the account and
  try to sign in.

Expect
: The token is shown once and never again. An expired or disabled account fails
  authentication on every channel, not just the browser.

Negative
: Disabling an account with sub-users offers to cascade; without cascade the
  sub-tree keeps working, which is a deliberate choice and should read as one.
