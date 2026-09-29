---
title: "SM579: a site collects, sends to a remote service, and shows what comes back"
subtitle: "Rescoped from 'connectors' to the workflow question the apps are actually asking. The engine can already POST a form to a URL. What it cannot do is hold a REUSABLE, credentialed connector that several forms, buttons and tables send through - the way smtp.conf holds the mail account once and every email handler references it."
brand: plain
standard-margins: true
status: partial
status-note: "VISITOR OUTCOME BUILT 2026-09-29 on claude/n193-what-the-visitor-is-told (stacked on SM857). The last row of phase 2 and the one that needed a ruling: a submission a connector took onward said 'your message has been sent', which on a connector-only form is the one thing that did not happen, and the only other state the banner had was form-status-error with role=alert - a working submission shown as a failure. RULED: a second engine-authored success state, worded 'Thank you - your submission has been received and sent for processing.' Author copy REFUSED on the measurement, not on taste: the no-JS path answers by redirecting to ?form=X&outcome=..., and a query string is writable by whoever composes the link, so per-handler text would let a crafted URL put anything on the page in the SUCCESS style. A TOKEN travels; each side holds a closed token => sentence map (%OUTCOME_SAID in plugins/form-handler.pl, %SAID beside the banner in lazysite-processor.pl) and looks the sentence up; a token neither side holds falls back to ok rather than being printed. Two copies because ADR 0001 keeps the render path module-free, so t/lint/156 holds them equal token for token - the _acl_allows_read shape, and a lint rather than a note because NOTHING ELSE WOULD FAIL if they drifted: a visitor would be told one thing with JavaScript and another without. The handler picks ok-processing from deliver's own answer (type => connector), never by re-reading the conf; a form with both a store and a service gets it, because the onward leg is the part the visitor could not otherwise know about. t/unit/forms/27 drives the real CGI against a REAL connector on a loopback HTTP::Daemon rather than a mock - http:// to 127.0.0.1 is what the connector layer permits, and t/unit/forms/20's T7 note is why a permissive mock is not evidence - with the store and connector cases asserted as a discriminating pair, so saying it everywhere fails as loudly as never saying it. SABOTAGING THE LINT FOUND A DEFECT IN THE LINT: its key pattern [a-z][a-z0-9-]* silently DROPPED a token it could not parse, so a bad token fell out of both maps and is_deeply would have compared two equally-incomplete maps and agreed. It now reads keys loosely and asserts what it read against the pair count the file declares. Docs: /docs/forms gains a what-the-visitor-is-told table and says why the wording is not configurable. PHASE 2 BUILT 2026-09-08 on claude/sm579-phase-2-the-connector-surface (stacked on SM775). All four of the things phase 1 named as not yet done. (1) THE MANAGER PAGE - starter/manager/connectors.md, built entirely from the style guide's existing vocabulary: no new class, no inline style (lint 108 requires zero on a page with no ceiling), every control declaring its data-impact (lint 109), and per-connector detail in THE ONE IDIOM, a row and its own card as the next sibling. Registering it found a defect before it shipped: the nav gates on manage_connectors and the PROCESSOR DID NOT DERIVE IT, so the entry would have been invisible to everyone including its holder (lint 83 asks exactly that). (2) THE ROW SOURCE - the caller sends a KEY, never a payload, and the connector's row_map decides which columns leave; an unmapped column is not sent, including one added later, which is the filing's own proving test. The row is read as the calling account through the data store's own rules (SM476). (3) SCHEDULED INVOCATION, mode 1 - one engine job (connectors-call, every 300s) that calls every connector whose declared schedule_every has elapsed, with a fixed flat schedule_payload; %JOBS stays the closed literal the daemon security review re-verified. Due-ness comes from the CALL RECORD, so there is no second store to disagree with it. (4) THE MCP SURFACE, DECIDED - connector_call gets a twin because it IS mode 2, gated by the connector itself; save, secret-set and delete do NOT, and that is a refusal rather than a gap, recorded in lint 23 with its reason: an agent that could save a connector could point the site at an internal address. PHASE 1 BUILT 2026-09-07 (0.13.5, claude/sm579-a-site-sends-through-a-connector-and-keeps-what-comes-back) on the five decisions taken that morning: the answer lands in a data-table row; form fields and table rows only, never a file; manage_connectors to configure; one audit row per call naming connector, trigger, mode and data class, never the payload; a call that never answers is unanswered, listed by state. Lazysite::Manager::Connectors (store, secrets 0600 apart, may_call by declared modes and callers groups, rate cap per hour, call over LWP with the secret in a named header, answer kept via Data::Tables::insert_row, calls.jsonl record), six control-API actions (connector-list/save/secret-set/delete/calls under manage_connectors; connector-call reachable by any authenticated caller and gated by the connector), the `connector` form handler (mode 3, refused unless the connector opts in), the connectors-sweep scheduler job, /docs/connectors, SECURITY.md, the capability through its parity points. NOT YET: the manager page (API-first), scheduled invocation (mode 1), MCP twins, sending table rows from a page action (only the API caller supplies a row today). Earlier: RESCOPED 2026-08-30 by the release manager, from 'a connector' to THE WORKFLOW QUESTION, and named as the next major feature after 0.11.8. The shape asked for: a trigger in the site (a form submission, or something else) gathers data from FORM FIELDS, a DATA TABLE, FILES and ATTACHMENTS, sends it to a remote service, and that service answers with links or messages that come back into the site. THE CONSTRAINT THAT DECIDES THE DESIGN: there is no listener. Nothing can trigger this instance from outside until the persistent runtime exists (SM666), so the return leg cannot be a callback - it is the site asking again, and in the meantime the honest answer to a visitor is 'check back in five minutes'. THE BOUNDARY THE RELEASE MANAGER SET: lazysite must not become more of a multipurpose tool. This is not a workflow engine, a scheduler or an integration platform; it is one bounded act - collect, send, wait, show - and every generalisation of it should be refused by default. PREVIOUSLY, and still true as the starting point:REQUESTED BY THE OPERATOR 2026-08-25: a plugin function a page can call out to an API with, set up like SMTP - configure connectors, then wire them on; triggered by a form post OR a user button press; the data coming from the form OR from a data table. WHAT ALREADY EXISTS, verified in plugins/form-handler.pl: a `webhook` handler type is declared (name, enabled, url, format json|slack) and dispatch accepts both `webhook` and `api`, calling dispatch_webhook - which POSTs the non-underscore form fields as JSON through LWP::UserAgent with a 10s timeout and logs a WARN on failure. So FORM -> one URL already works. WHAT IS MISSING is everything that makes it a connector rather than a URL field: (1) a NAMED, REUSABLE connector holding endpoint, method, headers and CREDENTIALS in the reserved tree the way lazysite/forms/smtp.conf does, referenced by name from any number of handlers, so a key is written once and never appears in a per-form config an author can read; (2) a BUTTON trigger - a page control that sends without being a form submission; (3) a DATA TABLE source - sending a row (or a query's rows) rather than only the fields a visitor just typed; (4) the delivery discipline the existing webhook lacks: retry/timeout policy, an audit entry per call, and a visitor-facing outcome. PLANNED as a design; the security section below is the part that decides the shape and wants the operator's ruling before anything is built."
---

> **A service of [[SM666]], the persistent runtime.** Reduced 2026-09-03, and it gains rather than loses. This filing already named the constraint that decides its design - "there is no listener" until the persistent runtime exists - so the return leg could only ever be the site asking again. With the runtime, a callback becomes possible and the five-minute wait stops being the honest answer. It is also the OUTBOUND POLICY module for the whole programme: allowlist, credentials, timeouts, retry, audit per call. The daemon's phase 1 deliberately has no egress so that it inherits those controls from here rather than growing its own. The release manager's boundary is unchanged - one bounded act, collect, send, wait, show, and every generalisation refused by default.

# Phase 2, and what is still open

Phase 2 (2026-09-08) closed the four things phase 1 listed as not yet done: the
manager page, the row source, scheduled invocation, and the MCP surface. Two
decisions inside it are worth finding again:

- **A row-sourced call sends a KEY, not a payload**, and the connector's
  `row_map` decides which columns leave. `row_map` is required rather than
  "send the row" because a table gaining a column must not silently widen what
  leaves the site.
- **Configuring a connector has no agent surface**, and that is a refusal
  rather than a gap. Writing a destination and setting a credential are
  operator acts at a human surface, because an agent that could save a
  connector could point the site at an internal address. Calling one does have
  a twin, because that is mode 2 and the connector already gates it.

Still open, and deliberately not folded in here:

- ~~**[[SM790]]** - the wire.~~ **DONE, and this list said otherwise until
  2026-09-28.** SM790 shipped (`ccd2535d`): the call path no longer trusts what
  the remote sends back. The reasoning for keeping it out of a phase was right and
  it was built where it belonged; what was wrong is that this list went on naming
  it as open, which is how a filing reads as more blocked than it is.
- **Spend caps** as distinct from rate caps, for the model-call case named
  below.
- A **visitor-facing outcome** for a public call: the SM415 banner shape, and
  the honest "check back" answer while there is no callback. **BUILT 2026-09-29
  on the ruling below** (PENDING). Both sides carry a closed `token => sentence`
  map - `%OUTCOME_SAID` in `plugins/form-handler.pl`, `%SAID` beside the banner
  in `lazysite-processor.pl` - because ADR 0001 keeps the render path
  module-free and the two cannot share code; `t/lint/156` holds them equal token
  for token, the same shape `_acl_allows_read` and `t/lint/36` already use. The
  handler picks `ok-processing` when any target's delivery came back
  `type => connector`, read from `deliver`'s own answer rather than by re-reading
  the conf. `t/unit/forms/27` drives the real CGI against a real connector on a
  loopback `HTTP::Daemon` (no mock - `http://` to 127.0.0.1 is what the connector
  layer permits) and proves the pair discriminates: a store target still says
  `outcome=ok`, a connector target says `ok-processing`, and a form with both
  says `ok-processing` because the onward leg is the part the visitor could not
  otherwise know about. An unknown token falls back to `ok` rather than
  travelling, which is what keeps the closed map closed from the inside.
  The two things measured before building, which the row had assumed away:

  1. **The SM415 banner has only two states, and the second is styled as a
     failure.** `outcome=ok` renders a hard-coded "Thank you - your message has
     been sent." in `form-status-ok`; *anything else* renders in
     `form-status-error` with `role="alert"`. So a connector call that
     succeeded cannot say anything other than that one sentence without being
     shown to the visitor as an error. Today every successful submission says it
     - including one that sent a photograph to be read and stored a row, where
     nothing was sent to a person at all.
  2. **The query string is attacker-writable by construction** (the renderer's
     own comment says so), so author copy cannot travel in it. A crafted link
     could put any text on the page in the SUCCESS style, which is a materially
     better phishing aid than the error banner already is. Carrying a short
     token and looking the text up is the safe shape - and the processor does
     **not** read `lazysite/forms/<name>.conf` or `handlers.conf` today, and the
     render path is deliberately module-free (ADR 0001), so where the text lives
     is the decision.

  **RULED 2026-09-29: (a), an engine-authored second success state**, and the
wording is

> Thank you - your submission has been received and sent for processing.

It is true whether or not the connector keeps an answer, and it promises
neither a reply nor a page - which the "check back in a few minutes"
phrasing could not, because only the author knows whether the site shows the
answer anywhere. Author copy was refused for the reason measured above: the
query string is attacker-writable, so per-handler text needs a carrier that
cannot be forged, and that means a new render-path read under ADR 0001.

The options as they were put:

**The decision was between:** (a) a second engine-authored success state
  (`ok-pending` or similar) with wording the release manager chooses - no author
  copy, no new render-path input, and the wording has to be true for every
  connector, so it cannot promise that a page will show the answer; or (b)
  per-handler author copy, which needs a carrier the query string cannot forge
  and therefore a new render-path read. Nothing was built, because picking
  visitor-facing copy for live forms is not a dev call and (b) changes what the
  render path loads.

# What exists, and what a connector adds

| | Today (`webhook` handler) | A connector |
|---|---|---|
| Where the endpoint lives | a `url` field in each form's own config | one named connector in the reserved tree |
| Credentials | none - the URL is the whole secret | headers/auth held once, never in a per-form file |
| Reuse | copy the URL into each form | reference the connector by name |
| Triggers | a form post | a form post, a button, a table row |
| Payload | the form's own fields | form fields, or a mapped table row |

# The security questions that decide the design

These are not caveats to a settled design; they are the design.

**Who may name a destination?** The URL is the whole exposure: an engine
that POSTs wherever an author says is an SSRF engine, reaching
`localhost`, a cloud metadata endpoint or a neighbouring site. The
existing `handlers.conf` pattern already answers this for forms - a
handler is operator-vetted and an author only *binds* to it - and a
connector must follow it exactly: **the operator writes connectors; an
author references one by name and can never supply a URL.** An allowlist
of destination hosts, checked at call time rather than only at config
time, is the belt to that brace.

**Where do the credentials live?** Beside SMTP's, in the reserved tree
(`lazysite/forms/smtp.conf` is blocklisted, capability-gated and never
echoed). A connector file must be the same, and the manager must show a
key as set-or-unset rather than as a value.

**What can a visitor cause?** A button that calls out is a relay: without
the discipline forms already carry (the timestamp+HMAC window, the
per-form rate limit, quarantine), a page becomes a way to make the site
send traffic to a third party on demand. A button trigger inherits the
form gates or it does not ship.

**What does the visitor wait for?** An outbound call in the request path
holds the response open. A timeout is mandatory; a queued/asynchronous
mode is the honest answer for anything slow, and the SM415 outcome
banner is the shape for telling a person what happened.

**Is a call a data-handling event?** Sending a submission - or a table
row - to a third party is exactly that. Every call is audited with its
connector, its trigger and its outcome, and never its payload.

# Sending table rows

A row source is a read of the data store, so it answers the store's own
rules: the table's `public` flag defaults closed (SM476), and a
connector sending rows needs the capability that reads them. A mapping
(`column=field`) is required rather than "send the row", for the reason
the `db` handler already gives: a table gaining a column must not
silently start sending it.

# Proving tests

- An author-supplied URL is refused; only a named connector resolves.
- A connector's credential never appears in any manager response, any
  form config, or any audit line.
- A button trigger without a valid form token is refused, and the
  per-form rate limit applies to it.
- A call is audited with connector, trigger and outcome; the payload is
  not in the audit line.
- A table-sourced call sends only mapped columns; an unmapped new column
  is not sent.
- A connector whose host is not allowlisted is refused at call time.

# Register

An outbound interface is a significant change: `docs/SECURITY.md` gains
an entry in the shape git-sync's egress entry uses (what changed / threat
delta), because this adds an SSRF-shaped surface and a credential at
rest.

# The workflow question (release manager, 2026-08-30)

This filing began as "a reusable connector". The request behind it is larger and
worth stating in its own words, because the shape of the answer follows from it:

> there are apps that require to trigger external functions, then collect
> responses. this may be the result of a form submission or other trigger in the
> site. then collected data from the variables, database, files and attachments
> might then be sent to a remote service, and that service may return with some
> links or messages. until the listener real-time daemon is built, we can't be
> remotely triggered, so we may need to leave it with user to recheck in 5 mins
> or whatever.

## The boundary, first

**lazysite must not become more of a multipurpose tool.** That is the governing
constraint, and it is easier to hold now than after the first three features have
been added to a workflow engine that did not mean to become one.

So this is **one bounded act**, not a platform:

> Something happens in the site. Data is gathered. It goes to one remote
> service. The answer comes back and is shown.

Everything that generalises that should be refused by default and argued for
individually: branching, conditionals, multiple steps, fan-out to several
services, scheduling, retries as a user-visible concept, a designer UI for
sequences. Each is reasonable on its own and the sum of them is a product this
project has said it does not want to be.

The test to apply to any addition: **does an app need this, or would a workflow
engine have it?** The second is not a reason.

## What makes this different from the webhook that already exists

Today `plugins/form-handler.pl` POSTs a form's fields to one URL and logs a
warning if that fails. Four things are missing, and only the first was in the
original filing:

1. **The data is not just the form.** A submission is one trigger among several,
   and what gets sent may include rows from a data table, a file, an attachment,
   and site variables - assembled deliberately rather than being whatever the
   visitor typed.
2. **There is a RETURN LEG.** The existing webhook is fire-and-forget. This has
   an answer that matters - links, messages - and that answer has to land
   somewhere a page can render it.
3. **The credential is reusable and hidden.** A named connector holding endpoint,
   method, headers and secrets the way `smtp.conf` holds the mail account, so a
   key is written once and never sits in a per-form config an author can read.
4. **Nothing can call us back.**

## The fourth is the one that decides the design

**There is no listener.** Nothing outside can trigger this instance until the
persistent runtime exists ([[SM666]]), and until then a remote service cannot
call back with its answer.

So the return leg is not a callback. It is **the site asking again**, and that
forces three things into the design that a callback-based design would not need:

- **A durable record of the in-flight request** - what was sent, when, to which
  connector, and what it is waiting for. That record is the workflow; there is
  no other state.
- **A way to ask again** that is not a background job, because there is no
  background. Realistically: the visitor's own next page load, or an operator
  action, or a request the page makes on a timer while somebody is looking at it.
- **An honest thing to tell the visitor.** The release manager's own phrasing is
  the right one: *check back in five minutes*. A page that pretends to be
  waiting, or spins forever, is worse than one that says plainly that the answer
  is not here yet and how to come back for it.

That last point is worth holding onto when the daemon does arrive. The
"come back later" state will still be the honest answer whenever the remote
service is slow, so it is not scaffolding to be thrown away - it is the design,
and the daemon only removes the polling.


# How an egress call may be invoked (release manager, 2026-09-03)

**This is the rule that decides the design, and it applies to every outbound
call regardless of what is at the other end.** A webhook, a REST connector, an
Odoo query ([[SM747]]) and a model call are **the same shape**: something in the
site causes this instance to talk to somewhere else. The differences are in the
payload, not in the risk.

The risk is not "what does the remote service do". It is **who can cause the
call to happen**. Three modes are sanctioned, and nothing else is:

**1. Pre-set, invoked by the timer.** The scheduler ([[SM666]]) calls it. No
caller-supplied input reaches the remote service at all - the job is engine code
and its parameters are configuration. This is the safest mode by construction,
because there is no request to abuse.

**2. Invoked by a logged-in user who holds the capability for it.** Attributable
to a person, rate-limitable per identity, revocable by removing a grant. The
ordinary authenticated case.

**3. Backing a public service, with bounded input.** A public form may trigger
it. This is the mode that can be abused, and the bounding is what makes it
safe - the input must be **canned** rather than free.

## Why the third mode is guidance and not enforcement

The distinction that matters is one the engine cannot see.

A form field offering a **select with fixed options** is bounded: the set of
things that can reach the remote service is finite and chosen by the
implementor. A **free textbox** is not bounded: whatever a visitor types goes
outward.

Both are just form fields. **We cannot police which one an implementor uses**,
and pretending otherwise would be a check that passes while the hazard walks
past it - the shape this project has met repeatedly. So for the input itself,
what we owe is **guidance in the practice docs**, stated plainly and with the
select-versus-textbox example, because that is the form the decision actually
takes for whoever is building.

## What IS enforceable, and therefore should be built

Guidance alone would be an abdication. The mode itself is declarable, and a
declaration can be enforced:

- **A connector declares which modes it permits.** One configured as
  scheduled-only **refuses a request-time invocation**, and one configured for
  authenticated use refuses an anonymous one. That is a real gate, checkable
  without knowing anything about the payload.
- **The public mode is opt-in and never the default.** A connector reachable
  from a public form says so explicitly in its configuration, so the dangerous
  mode requires a deliberate act rather than an omission.
- **Rate and spend caps apply in every mode**, because they do not depend on
  knowing whether the input was bounded. This is what stands between a
  free-textbox mistake and an unbounded bill.

So the division is: **the engine enforces WHO may invoke and HOW OFTEN; the
implementor bounds WHAT is sent, and we tell them how.**

## What this absorbs

**The model call is not a separate feature.** [[SM265]]'s `llm_proxy` deliverable
- a server-side proxy so the key never reaches the browser - is a connector of
this kind whose remote service happens to be a model. It belongs here, under
these three modes and these caps, rather than as its own surface with its own
answer to the same questions.

That is also the shape of the spend problem. A model call charged to an
operator-held key, reachable from a public form with a free textbox, is exactly
mode 3 without bounding - and the cap is the control that makes it survivable
rather than the guidance.

[[SM747]]'s per-site rate cap (OB5) is the same control seen from the Odoo end,
and should be this one rather than a second implementation.

## What this needs decided before anything is built

1. **Where does the answer live?** A data table row is the obvious home - it is
   already the engine's durable, queryable store, and a page can already render
   from one. If the answer is a table, this feature is mostly plumbing between
   things that exist.
2. **What may a connector be sent?** Form fields and table rows are clear. Files
   and attachments are not: sending a file to a third party is a disclosure, and
   the rule for which files a connector may read has to be an ACL question, not
   a configuration one.
3. **Who may configure one?** Creating a connector means naming a destination for
   site data and holding a credential for it. That is a conferral in the SM647 /
   SM682 sense - the authority to decide where data goes - and it should require
   authority over the data, not merely over pages.
4. **What is recorded?** Every call to a remote service is a disclosure event. An
   audit entry per call, saying which connector, which trigger, and what class of
   data - never the payload itself.
5. **What happens when it never answers?** A request with no reply is the normal
   case at least once. There has to be a state for it that is not "waiting", and
   an operator has to be able to see the stuck ones.

## Sequencing

Not for 0.11.8. Named here because the information arrived and belongs on the
record while it is fresh; the release manager's expectation is that it is the
next major feature after the 0.11.8 edge.

It also sits behind two things already filed: [[SM666]] (the runtime, which
removes the polling) and the data-table work, since the answer most likely lands
in a table. Neither blocks a first version - the polling design is honest without
the daemon - but both change how much of this is plumbing rather than new
machinery.
