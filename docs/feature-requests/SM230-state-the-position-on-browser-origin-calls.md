---
title: "SM230 - State the position on browser-origin calls"
subtitle: "The control API has no CORS and no preflight handling, by design. Silence reads as an oversight, and every browser-side integrator re-derives it the expensive way."
brand: plain
status: candidate
status-note: "Raised 2026-08-06. Documentation plus a small diagnostic. A partner in August 2026 listed 'does the control API accept a browser origin?' among three questions only the maintainer could answer; the answer is a firm no and has always been. Implementation targeted for the next release."
---

# SM230 - state the position on browser-origin calls

## Why

The control API accepts no cross-origin request from a browser page. There is no
`Access-Control-Allow-Origin` on any control-API response and no `OPTIONS`
preflight handling. The only cross-origin responses anywhere in the platform are
two service-discovery documents - `/.well-known/lazysite-instance.json` and
`/.well-known/ai-partner` - which are deliberately open so a browser-side
onboarding probe can find an instance.

This is a design position, not an omission. lazysite's authenticated surfaces
are for agents, scripts and the manager, all of which hold operator-issued
credentials. A browser page on an arbitrary origin holds none, and a credential
that a browser could hold is a credential that is exposed.

Nothing states this. A capable reader inspecting the tool surface finds no CORS,
cannot tell whether that is policy or an unimplemented detail, and has to ask.
In August 2026 a partner listed it among three questions *"only you can
answer"*, and correctly noted that a yes would have made their entire
specification substantially smaller. Answering it in documentation costs a
paragraph; answering it by correspondence costs a round trip and, in that case,
a design that had already been written both ways.

## What to write

### 1. A stated position in `/docs/api`

One short section: browser-origin calls to the control API are out of scope, the
reason, and what to do instead. The reason is the substantive part - a partner
who understands *why* will not propose a variant that has the same problem.

The alternatives worth naming, because they are what people actually want:

- **A form POST.** Anonymous, same-origin, field-validated, stored, and it
  raises a notification. This is the supported way for a browser to send
  something to a lazysite site.
- **A static application plus an agent.** The page is served from the site; the
  privileged work happens through MCP or the control API from somewhere holding
  a credential.
- **The public read path.** Anything a browser may read without a credential is
  already readable, same-origin, with no CORS involved.

### 2. A paragraph in `/docs/ai-briefing-publishing`

Partners designing integrations read this briefing. It should say the control
API is not callable from a page, so the design goes the right way the first
time.

### 3. Make the refusal legible

A cross-origin request to the control API currently fails in the browser with a
CORS error that names no cause on the server side and leaves nothing in the log
an operator could correlate. A single `OPTIONS` handler that returns a clear
refusal - and logs it - turns an opaque browser-console failure into a
diagnosable event, without granting anything.

This is the one code change in the request and it should be scoped tightly:
answer the preflight with an explicit refusal, do not emit
`Access-Control-Allow-Origin`, and log the origin that attempted it. The
position does not change; only its legibility does.

## Verification

- `/docs/api` states the position and names the supported alternatives.
- `/docs/ai-briefing-publishing` carries the same statement in brief.
- A cross-origin preflight against the control API receives an explicit refusal
  and leaves a log line naming the origin.
- No control-API response gains a permissive CORS header; a test asserts their
  absence so this cannot be relaxed by accident.

## Not in scope

- Any browser-callable authenticated surface. If one is ever wanted it is a
  large, security-sensitive request in its own right, and it starts from a
  session-scoped credential model rather than from CORS headers.
- Changing the two open `.well-known` documents, which are intentionally
  cross-origin and carry no account data.
