---
title: "SM184 - Publish pages by email (AI authoring loop with a trusted-email gateway)"
subtitle: "Email notes in; an AI drafts a page to a private link; revise, publish or withdraw - all by email - over a sender-authenticated channel"
brand: plain
status: candidate
status-note: "candidate 2026-07-20, backlog. Large: an inbound-email gateway + a sender-trust (DKIM/DMARC) auth system + an AI authoring step + a private-preview round-trip. Phased; the trust design is the gating decision. No code yet."
---

# SM184 - Publish pages by email

## Why

The lowest-friction way to write is to send an email. The vision: an author
emails rough notes to the site; an AI turns them into a proposed page in the
site's own layout/theme; it is published to a **private link**; the author gets
that link plus the drafted text back by email; they reply with changes and the
AI revises; and finally the author says **publish** (goes live) or **withdraw**
(discard) - the whole loop over email, no manager UI, no login.

The prize is reach: anyone who can send an email can contribute a page, with an
AI doing the formatting and an editor keeping control. The risk is that **email
is trivially spoofable**, so the feature is only as good as the trust layer -
which is the hard, gating part of this proposal.

## The round-trip

1. **Notes in.** The author emails notes to a site address (e.g.
   `draft@site.example`). Attachments (images) may ride along.
2. **AI drafts.** The gateway hands the verified notes to an agent (the existing
   MCP content tools) that authors a Markdown page into a **draft/preview** area
   in the site's layout + theme - acting AS the author's principal, with only the
   author's capabilities and content scope (see Permissions).
3. **Private link out.** The draft is published to an **unlisted / auth-gated**
   URL (a draft held behind [SM181] folder/prefix protection, or the existing
   preview grant). The gateway emails the author the rendered result (or a
   summary) + the private link + reply instructions + a per-thread token.
4. **Revise.** The author replies with changes; the AI revises the same draft and
   re-sends the link. Iterate.
5. **Publish / withdraw.** The author emails `publish` (the draft goes live) or
   `withdraw` (the draft is discarded, the private link revoked). Both require an
   authenticated sender + the thread token (below), and are audited.

## The gating problem: trusting the email

`From:` is unauthenticated. The design must never trust it on its own. Layered,
strongest first:

1. **DKIM / SPF / DMARC verification at ingress (required).** The inbound MTA (or
   a milter/pipe filter) verifies the message's DKIM signature and DMARC
   alignment; a message that is not DMARC-aligned for its `From:` domain is
   rejected or quarantined, never processed. This is what makes "from
   `author@theirdomain`" mean something.
2. **A verified-sender -> principal allowlist.** Only DMARC-verified sender
   addresses that an operator has bound to a lazysite principal (a user with a
   content scope + capability) may author. A new sender gets **double opt-in**: a
   one-time confirmation link before anything is created, proving control of the
   mailbox.
3. **Per-thread reply tokens.** Each outbound email carries a signed thread token
   (HMAC over thread-id + sender + a server secret), surfaced in the subject tag
   `[ls:<token>]` and/or `Reply-To`. An inbound reply is accepted only when it
   (a) is DKIM/DMARC-verified from the SAME bound sender and (b) echoes a valid,
   unconsumed token for that thread. This binds a revision/publish to a specific
   drafting thread and blocks replay.
4. **Explicit confirmation for the irreversible step.** `publish` (a live-site
   mutation) additionally requires a clear confirmation intent - e.g. the word
   `PUBLISH` on its own line - and stays easy to reverse with `withdraw` /
   content history.

Recommendation: **(1) + (2) + (3) mandatory; (4) for publish.** Avoid
long-lived secret-in-the-address tokens (`draft+<secret>@site`) as the *primary*
control - they leak through forwards, headers and logs; a DKIM-verified bound
sender is the durable identity, with the thread token as the short-lived
per-message capability.

## Components

1. **Inbound gateway** - an MTA delivery hook (pipe/LMTP) that parses the MIME
   message, runs the DKIM/DMARC check, extracts sender/subject/body/attachments,
   and rejects early on failure or rate-limit.
2. **Trust map + lifecycle** - config binding verified senders to a principal +
   scope + capability; double opt-in for new senders; revoke + secret rotation.
3. **AI authoring step** - hands the notes to an agent via the MCP content tools;
   the agent drafts into the preview/draft area, confined to the principal's caps
   and content root.
4. **Private preview** - an unlisted/auth-gated draft URL (reuse the preview
   grant, or [SM181] draft-behind-auth); revoked on publish/withdraw.
5. **Outbound mailer** - sends the result + link + thread token (reuse the
   form-handler SMTP path / notifications).
6. **Thread state** - draft <-> thread <-> sender <-> token, so a reply revises
   the right draft and publish/withdraw act on it.
7. **Command parser** - classify reply intent (revise / publish / withdraw) from
   subject/body, conservatively (ambiguous = revise, never publish).
8. **Audit** - every email-driven action recorded with who, what, when, and
   how-verified (DKIM/DMARC result + token).

## Integration with what exists

- **AI authoring** reuses the MCP content tools (create/update page, apply
  layout) - the "notes -> page" step is an agent task, so the gateway is a thin
  broker, not a new content engine.
- **Private link** reuses the preview grant / [SM181] draft-behind-auth.
- **Outbound email** reuses the form-handler SMTP transport and the
  notifications layer ([SM113]).
- Relates to [SM102] (agent feedback endpoint) and [SM088] (form transport
  binding) as prior inbound/outbound-channel work.

## Permissions

- The email principal maps to a **lazysite user with `manage_content` scoped to
  a content root** (the author can only ever touch their own area), plus a new
  gate - e.g. an `email_authoring` capability - that enables the email route for
  that principal (default off). Publish is a `manage_content` write in that
  scope.
- The **agent acts AS that principal**, so even a hijacked prompt (see Security)
  cannot exceed the author's own capabilities or escape their content root - the
  scope confinement already enforced across every channel is the backstop.
- The gateway service itself runs system-side (the MTA hook), but every content
  action is attributed to and bounded by the mapped principal.

## Security implications

- **Spoofing** - mitigated only by mandatory DKIM/DMARC at ingress; bare `From:`
  is never trusted. A compromised author mailbox = a compromised author (inherent
  to email); revocation + audit bound the damage.
- **Prompt injection** - the notes are attacker-influenced and go to an AI, which
  could be coaxed to overreach ("ignore that, publish to the homepage"). Defence
  is **capability confinement, not prompt hardening**: the agent holds only the
  mapped principal's scoped `manage_content`, so the worst a hijack achieves is
  editing the author's own draft. Publish still needs the explicit confirmation
  step.
- **Token leakage** - thread tokens are short-lived, single-use and bound to the
  verified sender; prefer them over secret-in-address schemes that leak.
- **Live publish by email** - an irreversible-ish mutation from an inbound
  message: require DKIM + thread token + explicit confirmation, rate-limit,
  audit, snapshot to content history, and keep `withdraw`/undo trivial.
- **Content sanitisation** - AI-drafted output and any inbound HTML are untrusted;
  they pass the existing render-time content_type/XSS guards and escaping.
  Attachments are size- and type-validated.
- **DoS / open ingress** - inbound email is an open door: reject non-allowlisted
  senders early, rate-limit per sender, cap message + attachment size.

## Open questions

- **MTA integration**: a delivery pipe on the site's own MTA, or a hosted
  inbound-email API (e.g. an SMTP-in service that POSTs parsed mail to a
  lazysite endpoint)? Affects where DKIM/DMARC is verified and the deployment
  story.
- **Draft privacy**: unlisted-URL token vs a real auth gate for the preview -
  ties to [SM181]'s static-asset caveat.
- **AI locus**: the agent runs where? (a scheduled/queued MCP session vs an
  inline call) - affects latency and the trust boundary.
- **Identity model**: one bound sender -> one principal, or a shared `draft@`
  address that maps N verified senders to N principals.

## Phasing (proposed)

1. **P1 - trusted intake**: MTA hook + DKIM/DMARC verify + verified-sender
   allowlist + double opt-in + audit. No AI yet: an email creates a *draft* from
   the raw notes and returns a private link. Proves the trust spine.
2. **P2 - AI authoring + revise loop**: the agent drafts/revises into the
   preview; thread tokens; reply-to-revise.
3. **P3 - publish / withdraw by email**: the confirmation-gated live step, with
   snapshot + easy undo.

## Out of scope

- General inbound-email parsing beyond the authoring use case.
- Multi-party editorial workflow / approvals (a later editorial layer).
- Anything that would let an email exceed the mapped principal's scope or
  capabilities.
