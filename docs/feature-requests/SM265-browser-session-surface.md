---
title: "SM265 - A session-scoped browser surface: model call, private store, raw asset"
subtitle: "Four authenticated authoring channels and one anonymous read path, and a single-file browser app fits none of them. A fifth surface, narrow verb set, short-lived token, capability-gated like the other four."
brand: plain
status: candidate
status-note: "Raised from the Golden Link / lazysite.agency Studio build spec (Alexander, August 2026), found unprocessed in the inbox 2026-08-09 under a filename describing a different defect. Supersedes nothing; SM230 already answered its third question (browser origins: a firm no) and shipped. The OTHER TWO questions are now answered too and both answers shrink the work: the content ACL DOES gate the anonymous read path as of SM223, and a source-less .html IS served byte-for-byte (SM133). Four deliverables, none built: llm_proxy, app_state, raw asset serving, and the browser session token that makes the first three safe to expose. Partner-blocking: phases 0-2 were wanted for September 2026."
---

# SM265 - a session-scoped browser surface

## Why

lazysite has four authenticated authoring channels - the manager UI, the control
API, MCP and WebDAV - and one anonymous read path. Every one of the four is
authenticated with an operator-issued credential held by a person or an agent.

A single-file browser application holds none of them. The partner's phrasing is
the clearest statement of the gap:

> A browser sitting on goldenlink.agency at 09:00 on a Sunday in Sintra holds
> none of them. What is missing is not features. It is a fifth surface: a
> session-scoped browser channel, narrow verb set, short-lived token,
> capability-gated exactly like the other four.

Two applications need it: The Golden Link (a facilitated workshop tool) and the
lazysite.agency Studio. Both are single browser files that need three things the
platform does not expose to an anonymous browser - **a model call, a private
read-write store, and a static asset served byte-for-byte** - plus a token that
makes exposing them safe.

## Provenance, and why this filing exists

The build spec arrived in the inbox and sat unprocessed. It was filed under
`form-timestamp-caching-defect-2026-07-28.md`, a name describing an unrelated
defect (SM252, long since shipped), so nothing about the filename suggested it
contained a platform requirement. It was found on 2026-08-09 while clearing the
inbox.

Recording that because the failure is repeatable: a document whose name does not
describe its contents is invisible to everyone who was not in the room when it
arrived, and this one carried a partner's September delivery.

## The three questions, answered

The spec ends with three questions "only you can answer", and states that the
answers materially change its size. All three are now answerable from the
codebase.

### 1. Does the content ACL gate the anonymous HTTP read path?

**Yes - as of SM223, which shipped after the spec was written.** The read list in
`lazysite/auth/acls.json` now governs the anonymous read path as well as the four
authoring channels, and a folder entry covers everything beneath it (SM181).

The spec says this answer shrinks Deliverable 2 "to a day": the state store can
be a thin wrapper over the content namespace rather than carrying its own
enforcement. That is now the case, with one caveat the designer needs:

- The ACL gates **reads**. A browser app also needs to **write** its state, and
  the anonymous path has no write channel at all. So the store still needs a
  write verb; what it no longer needs is a separate read-authorisation model.
- On a site with any ACL entry, every static request goes through the engine
  (SM223's stated cost). An app polling its state pays that on each call.

### 2. Is a `.html` in the content namespace served byte-for-byte?

**Yes.** A `.html` with no `.md` or `.url` source beside it is served verbatim -
the SM133 static fallback, present on Apache (a rewrite) and in the engine (for
other front ends). It is not rendered, and no layout wraps it.

Two constraints that matter for a single-file app:

- a `.md` source with the same basename **shadows** it, so the app file must not
  collide with a page name;
- on a site with an ACL store, that file is routed through the engine (SM223),
  so it is no longer served directly by the web server. It is still byte-for-byte.

### 3. Does the control API accept a browser origin?

**No, deliberately, and it always has been no.** SM230 was raised from this same
question and shipped in the 0.10.2 edge line: the position is documented and
`t/lint/21-no-cors-on-control-api.t` pins it, so no CORS header can be added by
accident.

The spec says a yes would have made Deliverables 1, 2 and 5 "new actions on an
existing surface rather than a new surface". The answer is no, so the fifth
surface is real work rather than a set of additional actions.

## The four deliverables

None of these is built. Summarised from the spec; the spec itself is the detail,
and is archived at `inbox/archive/2026-08-09-golden-link-build-spec.md`.

### 1. `llm_proxy` - the model call

A server-side proxy so the model key never reaches the browser. Synchronous, with
a **180-second timeout** - the spec calls this "the one thing likely to bite",
because a full deck synthesis runs long and venue wifi is unreliable. No
streaming: both apps wait for a complete JSON object.

### 2. `app_state` - a private JSON key-value store

Per-app, per-session state. ETags for concurrency - two facilitators on two
laptops editing the same participant must not lose each other's work. Explicitly
**not** a database; a JSON store on the filesystem is sufficient at this scale.

Now substantially smaller, given answer 1.

### 3. Raw asset serving

Answered: it already works (question 2). What remains is confirming behaviour
under an ACL store and documenting the shadowing constraint.

### 4. The browser session token

The piece that makes the other three safe: short-lived, session-scoped,
capability-gated like every other credential. This is the actual security design
and the reason the other three cannot simply be opened up.

## What is explicitly NOT wanted

Recorded verbatim from the spec, because unbuilt scope is the expensive kind:

- no database - a filesystem JSON store is sufficient;
- no server-side rendering of either app - they are single files and stay so;
- no file upload endpoint - photographs go to the model as base64 in the request
  body and are never stored server-side;
- no server-side document generation - the `.pptx` is built in the browser and
  the output has been validated;
- no websockets, no realtime, no collaborative editing - ETags are enough;
- no streaming.

That list rules out SM221 (the real-time proxy daemon bridging the control API to
WebSocket) as the answer to this. The two look adjacent and are not: this needs a
request/response surface with a short-lived token, not a persistent channel.

## Build order, from the spec

| Phase | What | Effort | Done when |
|---|---|---|---|
| 0 | Capability grants, domains, raw-serving answer | hours | The app loads at a Golden Link URL and completes a session with a pasted key |
| 1 | `llm_proxy`, sync, 180s timeout | 1-2 days | A deck synthesis completes with no key in the browser, on venue wifi |
| 2 | Session token, then `app_state` | 3-4 days | Two facilitators on two laptops edit the same participant, neither loses work |
| 3 | `/api/publish` via site packages | 3-5 days | The Studio takes a questionnaire to a live, rollback-able site without MCP |

Phase 0's blocking question is answered, so it is unblocked now. Phases 0-2 were
wanted for September 2026.

## What this needs before it starts

An operator decision on the security design, because this is a new anonymous-ish
surface on a platform whose other four are all operator-credentialled:

1. **What mints the browser session token, and on whose authority?** The apps are
   served from a lazysite site; the token has to come from somewhere that is not
   itself anonymous.
2. **What is the blast radius of a stolen token?** Short-lived bounds it in time;
   the verb set bounds it in scope. Both need stating before either is built.
3. **Does `llm_proxy` charge to an operator-held key?** If so, an anonymous
   browser can spend the operator's model budget, and rate limiting is part of
   the deliverable rather than a follow-up.

## Relationship to other filings

- **SM230** answered question 3 and shipped. This filing does not repeat it.
- **SM223 / SM181** answered question 1 by shipping the ACL on the read path.
- **SM221** is NOT this - see the not-wanted list.
- **SM158 / SM183** (site packages) are what phase 3's `/api/publish` builds on.
