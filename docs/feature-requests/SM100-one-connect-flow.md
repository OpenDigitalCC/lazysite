---
title: "SM100 - one 'Connect' flow per account (not three credential controls)"
subtitle: "Pick the client once; get the one credential that works"
brand: plain
---

::: widebox
A partner account shows three credential controls - **Token (Generate credential)**,
**Connect an AI assistant** (OAuth), **Generate agent brief** (pairing key) - and
which one works depends on the *client*, not the account: Claude.ai / ChatGPT **web
are OAuth-only** (no token field), so the static token cannot work there; Claude
Code / Desktop / scripts use the token or pairing brief. The operator has to know
this and pick correctly, and a wrong pick fails confusingly (the live report: only
the OAuth "Connect an AI assistant" worked for Claude.ai; the Claude Code token did
not). Replace the three with **one Connect flow** that asks the client and issues the
single credential that works.
:::

## Why

Observed live connecting Claude.ai: the operator tried "Generate credential" (the
Claude Code box) first, it didn't work (web is OAuth-only), and only the OAuth flow
did. Three parallel controls, each right for a different client, is the confusion.

## Shape

One primary **"Connect an AI assistant"** button per partner account. Clicking it
asks **which client**, then issues exactly the right credential:

```datatable
columns: Client | What it issues
widths: 6cm | X
bold: 1
tone: medium
---
Claude.ai / ChatGPT (web) | OAuth connect code + the connector URL (the existing onboarding-web flow). No token.
Claude Desktop / Claude Code | a static lzs_ token (or the pairing-key brief), shown once, + the endpoint.
A script / WebDAV | the lzs_ token + the WebDAV/API URL + username.
```

- **Reissue** is the same button: it revokes the prior credential and issues a fresh
  one of the chosen kind (one live credential per account already - SM072).
- The standalone "Token (Generate credential)" and "Generate agent brief" controls
  fold into this branch, so there is a single obvious entry point.
- Carry the existing guidance inline (e.g. "web has no token field - we'll give you
  a connect code") so the *reason* is visible at the moment of choice, not in a
  tooltip after a failure.

## Relationship

Part of the Users-page UX cleanup ([[SM094]]): with capabilities hidden when an
operator role overrides them, AI-account credential controls reduced to interactive
vs token (SM094 item 3), and now the connector credentialing reduced to one flow, a
partner account reads as "what is this account, and how does it connect" with no
dead-ends.

## Status

**SHIPPED in v0.4.25.** (see CHANGELOG)


Queued. Bounded UI change in `starter/manager/users.md` over the existing
`onboarding-web` / `token` / `onboarding` actions - no new server action; it just
routes to the right existing one based on the chosen client.
