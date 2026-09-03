---
title: "SM579: a site collects, sends to a remote service, and shows what comes back"
subtitle: "Rescoped from 'connectors' to the workflow question the apps are actually asking. The engine can already POST a form to a URL. What it cannot do is hold a REUSABLE, credentialed connector that several forms, buttons and tables send through - the way smtp.conf holds the mail account once and every email handler references it."
brand: plain
standard-margins: true
status: candidate
status-note: "RESCOPED 2026-08-30 by the release manager, from 'a connector' to THE WORKFLOW QUESTION, and named as the next major feature after 0.11.8. The shape asked for: a trigger in the site (a form submission, or something else) gathers data from FORM FIELDS, a DATA TABLE, FILES and ATTACHMENTS, sends it to a remote service, and that service answers with links or messages that come back into the site. THE CONSTRAINT THAT DECIDES THE DESIGN: there is no listener. Nothing can trigger this instance from outside until the persistent runtime exists (SM666), so the return leg cannot be a callback - it is the site asking again, and in the meantime the honest answer to a visitor is 'check back in five minutes'. THE BOUNDARY THE RELEASE MANAGER SET: lazysite must not become more of a multipurpose tool. This is not a workflow engine, a scheduler or an integration platform; it is one bounded act - collect, send, wait, show - and every generalisation of it should be refused by default. PREVIOUSLY, and still true as the starting point:REQUESTED BY THE OPERATOR 2026-08-25: a plugin function a page can call out to an API with, set up like SMTP - configure connectors, then wire them on; triggered by a form post OR a user button press; the data coming from the form OR from a data table. WHAT ALREADY EXISTS, verified in plugins/form-handler.pl: a `webhook` handler type is declared (name, enabled, url, format json|slack) and dispatch accepts both `webhook` and `api`, calling dispatch_webhook - which POSTs the non-underscore form fields as JSON through LWP::UserAgent with a 10s timeout and logs a WARN on failure. So FORM -> one URL already works. WHAT IS MISSING is everything that makes it a connector rather than a URL field: (1) a NAMED, REUSABLE connector holding endpoint, method, headers and CREDENTIALS in the reserved tree the way lazysite/forms/smtp.conf does, referenced by name from any number of handlers, so a key is written once and never appears in a per-form config an author can read; (2) a BUTTON trigger - a page control that sends without being a form submission; (3) a DATA TABLE source - sending a row (or a query's rows) rather than only the fields a visitor just typed; (4) the delivery discipline the existing webhook lacks: retry/timeout policy, an audit entry per call, and a visitor-facing outcome. PLANNED as a design; the security section below is the part that decides the shape and wants the operator's ruling before anything is built."
---

> **A service of [[SM666]], the persistent runtime.** Reduced 2026-09-03, and it gains rather than loses. This filing already named the constraint that decides its design - "there is no listener" until the persistent runtime exists - so the return leg could only ever be the site asking again. With the runtime, a callback becomes possible and the five-minute wait stops being the honest answer. It is also the OUTBOUND POLICY module for the whole programme: allowlist, credentials, timeouts, retry, audit per call. The daemon's phase 1 deliberately has no egress so that it inherits those controls from here rather than growing its own. The release manager's boundary is unchanged - one bounded act, collect, send, wait, show, and every generalisation refused by default.

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
