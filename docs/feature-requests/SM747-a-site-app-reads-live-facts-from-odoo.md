---
id: SM747
title: "SM747: the Odoo extension - a person uses Odoo through a lazysite page as themselves"
subtitle: "One filing for the whole Odoo extension: per-user authentication carried in a cookie, a signed identity context for rendering, a proxy transport in two modes, an MCP surface under the agent's own Odoo account, and the object mapper to be merged when its specification arrives. Consolidated 2026-09-26 from the odoo-bridge draft, the release manager's authentication briefing and its egress follow-up, and the engine's audit. Queued for a future release; nothing here is built."
brand: plain
standard-margins: true
status: candidate
status-note: "CONSOLIDATED 2026-09-26 at the release manager's direction: this filing is the authority for the Odoo extension. It absorbs the 2026-09-03 odoo-bridge draft (named queries, OOM as a package), the 2026-09-26 briefing (authentication, identity context, proxy transport - Parts 1 to 7, required outcomes 1 to 13, scope control), the same-day follow-up correcting the egress assumption, and the engine's egress audit. X4 RULED 2026-09-28, as recommended, all three questions together: the proxy does its own HTTP as mode 2 INSIDE SM579's policy rather than beside it (X4); no plain `http://` to an RFC1918 Odoo, `https://` to a private hostname being enough (X4-a); and general mode does supersede the original 'no raw passthrough, ever' when the credential on the wire is the user's own, the rule standing for a service account (X4-b). The register row is deleted, which is what the register asks for. THE PREREQUISITE THE RULING CREATED IS DONE AND RELEASED: SM579's invocation modes had to stop being connector-private before a proxy could declare itself mode 2 inside them, and `lib/Lazysite/Egress.pm` landed in 0.15.1 (`@MODES`, `may_invoke`, proved equivalent over 960 combinations; its comments already name `proxy` as a caller). THE MAPPER SPECIFICATION IS FILED 2026-10-01, at the release manager's direction, with its source path and sha256 recorded and t/lint/207 comparing the two whenever the OOM tree is readable - because this filing had by then gone stale against reality twice, and a second copy of a document still being edited elsewhere is how that happens. FILING IT CLOSED THREE SEAMS, LEFT TWO OPEN AND FOUND ONE NEW PIECE OF WORK. Closed: the proxy's request-shaping layer is `Odoo::Ops::Guard` and general mode is its absence, which is the division X4-b already ruled; onchange is never invoked, so a record created this way can differ from one a person creates in Odoo's UI and the extension's docs must say so; and the credential strategies are known. Open: whether Odoo field descriptors and the data extension's table descriptors can share a rendering layer (the shape is tested, the comparison is not made), and WHICH of the 12 CRM and 2 Comms operations become MCP tools - the spec settles the vocabulary, not the selection. NEW WORK: the per-user credential cookie needs `/web/session/authenticate` + `/web/dataset/call_kw`, a transport OOM does not have, and its `Credential` strategy REFUSES `session` and `cookie` by name - so Parts 2 and 3 carry a transport to build, which was invisible before the spec was filed. ONLY ONE GATE IS LEFT AND IT IS NOT ENGINEERING'S: OOM installed where this engine can reach it (OB7, OP-25). MEASURED 2026-10-01: the packaged `libodoo-oom-perl_0.01_all.deb` carries 8 modules, the MAPPER LAYER ONLY, against 41 in the tree - the 33 missing are the whole `Odoo::Ops::*` layer including the Guard, so installing it would give the engine general mode and no scoped mode at all. A 0.02 carrying both layers is a prerequisite of OP-25 rather than a later tidy, and nobody owns it. Zero lines of Odoo code exist in lazysite. One piece of work came OFF the build on 2026-09-28: OOM's transport is already hardened, so no injected transport is needed."
---

# Provenance, and what this filing now is

Four documents said what the Odoo extension should be, in three places and two
vocabularies. On 2026-09-26 the release manager directed that they be combined
here and that this filing be the authority. They were:

| Ref | Source | Date | Absorbed as |
| --- | --- | --- | --- |
| P1 | `odoo-bridge` plugin draft (the object mapper consumed as OOM; named queries) | 2026-09-03 | the *scoped* proxy mode, OB1 to OB7 |
| P2 | Briefing - Odoo plugin: authentication, identity context and proxy transport | 2026-09-26 | Parts 1 to 7, the settled decisions, required outcomes 1 to 13, scope control |
| P3 | Follow-up to the briefing - egress mechanism corrected | 2026-09-26 | the egress question and its three candidates |
| P4 | Engine audit - which egress policy applies to the proxy transport | 2026-09-26 | the finding, the recommendation, the engine notes |

The object-mapper specification the briefing calls "specified separately ... to
be merged into this spec" is **not in the tree** as of the consolidation. Its
seams are held open below and it is merged here when it is filed.

Where P1 and P2 disagreed, P2 wins and the disagreement is written down (see
*Reconciling the draft with the briefing*). Where the engine found the briefing's
assumptions wrong against the code, the finding is recorded and nothing was
changed silently.

Vocabulary: [[SM817]] ruled that lazysite's bundled plugins are **extensions**.
This filing says *extension* for the thing being built and keeps *plugin* only
where it quotes a source.

# The direction, 2026-10-01: Odoo as a headless ERP, and ONE way in

Given when the packaging question was put back, and it reframes this filing rather
than adding to it.

**The position.** Odoo is the headless ERP behind a set of functions; people reach
their part of it through lazysite interfaces customised to their role, and **the core
Odoo data stays the authority**. Named as likely in scope: invoicing, sales, quotes,
timesheets, expenses, stock movement, manufacturing and visitor registrations, "and
many other functions". The same construct is to serve projects that are not lazysite
at all.

**What is explicitly NOT wanted: lots of bespoke Odoo connectors.** One way it is
done. That is the constraint that matters most here, because it is the one a
succession of small reasonable decisions would quietly break.

## What that makes of this filing

SM747 is titled *a site app reads live facts from Odoo*, and it is sized and scoped
as one read-first slice: the CRM live facts for the stock-corrections portal, with a
scoped proxy and a general mode. **What is described above is an order of magnitude
larger** - role-scoped READ AND WRITE across most of an ERP, consumed by several
projects. It is a programme, and this filing is its first slice.

**That structural question is open and is the release manager's**: whether SM747 is
re-scoped as the programme, or a parent filing holds the programme with SM747 as
slice one. Nothing is renamed here on an assumption.

## The rule that makes "one way" structural rather than aspirational

The filed specification already puts the function knowledge in the right place, and
it is worth stating as a rule rather than leaving it as a happy accident:

> **Lazysite holds no Odoo knowledge.** Model names, field names, domains,
> `execute_kw`, RPC shapes and the ERP's semantics live in OOM's operation packs.
> Lazysite names an operation, binds its parameters, renders the descriptors it is
> handed, and presents a plan for confirmation.

Every new function is then **a new `Odoo::Ops::*` pack plus a lazysite interface that
names its operations** - never a new connector, and never a second place that knows
what an invoice is. Nine functions do not mean nine integrations; they mean nine
operation packs behind one door.

This is the difference between a rule and a hope: **it is checkable.** A lint
refusing any Odoo model name, `execute_kw`, or Odoo RPC endpoint in lazysite code
makes the boundary enforced rather than remembered. There is nothing to check today -
zero lines of Odoo code exist here - so the gate lands WITH the first code rather
than before it, and this paragraph is the record of why it exists when it does.

## And the role-scoping rule gets MORE load-bearing, not less

Scope control already says: do not reimplement Odoo's access model, and do not filter
results lazysite believes the user should not see - Odoo already did that. With one
read-only CRM view that rule is easy. With timesheets, expenses and stock movements
in front of contractors, suppliers and warehouse staff, **every one of those
interfaces will present an opportunity to filter in the wrong place**, and a page
that filters is a page that can be wrong in the direction nobody notices. The
credential on the wire is the user's own (X4-b), so Odoo's own ACLs are the bound. A
lazysite interface narrows what is ASKED FOR; it never narrows what came back.

## What it changes about the remaining gate

OB7 said OOM is consumed as a versioned package, never a copy, settled 2026-09-03.
The "never a copy" half stands and is not in question. **The SHAPE of the delivery is
reopened**: OOM is still under test and will have consumers beyond this engine, so
how it reaches them is a decision for all of them rather than a packaging chore for
this one - deb, versioned tarball, an internal service, or something else.

**I had written the opposite.** The sequencing row and OP-25 both said a 0.02 deb was
the prerequisite, which was me settling a question that is not mine. Both are
corrected. The measured gap stands on its own terms - whatever is delivered must
carry the `Odoo::Ops::*` layer, or there is no scoped mode - but that is a
requirement on the content, not an argument for a format.

**Nothing is blocked meanwhile.** Engine work can proceed against the OOM tree on a
library path, which is not a copy and ships nothing; what may not happen is a release
that depends on an arrangement nobody has decided.

# Why this is worth building properly (release manager, P2)

The immediate driver is helper apps, but the destination is larger: a
headless-ERP surface where lazysite is the interface layer and Odoo remains the
system of record.

Once a signed-in user's Odoo identity is available to lazysite at render time,
pages can be tailored by that user's Odoo groups and company, which makes
function-specific interfaces practical - a timesheet screen that shows one
worker exactly what they need, rather than teaching them to navigate Odoo. A
suite of such apps is the intended direction, so this foundation is built for
reuse, not for one app.

The same surface reached over MCP gives an agent the ability to do Odoo work
bounded by real Odoo permissions, with Odoo's own audit trail recording it. That
falls out of this work rather than needing its own project.

# Settled decisions (release manager, P2 - do not revisit)

1. **Lazysite stores NO Odoo credential server-side, ever.** The credential
   lives in an httpOnly cookie on the lazysite domain and is replayed on each
   proxied call.
2. **The browser never talks to Odoo directly.** All traffic goes through the
   lazysite proxy, so no CORS configuration is needed and Odoo may sit on an
   internal network reachable only by lazysite. This is a security property,
   not an implementation detail - preserve it.
3. **Odoo is the authority on authorisation.** Record rules, access rights,
   multi-company scoping and field-level access are enforced by Odoo per user
   and are NOT reimplemented.
4. **Odoo identity is SEPARATE from lazysite identity.** A lazysite account is
   not required to use an Odoo app. An optional mapping between the two may be
   stored later; credentials never are.
5. **Two proxy modes:** general (bounded only by the user's Odoo permissions,
   for the general interface) and scoped (an allowlist of models and methods,
   for a purpose-built app). Mode is per app, declared, not global.
6. **Strategies are pluggable.** Session authentication and API key ship first;
   a custom Odoo token module and OAuth arrive later without changing anything
   downstream.

# Requirements

The draft's OB rows are kept where they survive P2 and rewritten where they do
not; the briefing's parts are given rows of their own so the work can be
scheduled and closed by reference.

## Connection and transport

| Ref | Requirement |
| --- | --- |
| OB1 | Per-site Odoo connection in the extension's config: `odoo_url`, `odoo_db`, `odoo_strategies`, `odoo_timeout`, `odoo_identity_ttl`. No shared service account and no stored credential for the user-facing path. If the MCP surface needs a service account (OM1) it follows the mode-600 credentials-file convention and is never displayed. |
| OB2 | **Scoped mode**: a declared allowlist of models and permitted methods per app. Refused by lazysite before the call leaves. The default for a purpose-built app. (P1's "named queries" live here - a named query is a scoped allowlist with bound parameters.) |
| OB3 | **General mode**: no model or method allowlist; bounded by the user's own Odoo permissions exactly as Odoo's web client is. An allowlist here would mean enumerating Odoo badly and forever. **Applies only to a call made with the user's own credential** - see *Reconciling*. |
| OB4 | Caller gating is lazysite's: the proxy is reached by a lazysite session on an app page (mode 2 of [[SM579]]), and the call carries the Odoo credential from the cookie. No scheduled and no public mode for the per-user proxy. |
| OB5 | A per-call timeout (`odoo_timeout`); a rate cap per identity; Odoo faults mapped to lazysite's `{ ok: 0, error, kind }` shape with **distinct kinds** for session-expired, invalid-credential, odoo-access-refused and transport-failure. The fault's own text is logged, never returned verbatim (three leaks in three passes taught this - [[SM713]], [[SM738]], [[SM739]]; `t/lint/112` checks the source). |
| OB6 | Transport discipline, the connector's reused as behaviour: no redirect following - a 3xx is a named refusal, because the credential would travel with it; a response size cap sized for Odoo reads and configurable; TLS peer verification on; `https://` to any host and `http://` only to loopback. **X4-a settled this 2026-09-28: no plain `http://` to an RFC1918 Odoo** - `https://` to a private hostname, which the connector rule already permits, is what "internal network" means here. |
| OB7 | OOM is delivered as a versioned package (`libodoo-oom-perl`); the extension declares a minimum version in `owns.deps` and never carries a copy of the code. Settled by the release manager 2026-09-03. **MEASURED 2026-10-01: THE PACKAGE THAT EXISTS CANNOT SATISFY THIS.** `/srv/projects/packages/libodoo-oom-perl_0.01_all.deb` (2026-09-03, 26,972 bytes) carries **8 modules - the mapper layer only**: Client, Commands, Error, Model, Record, RecordSet and the two transports. The OOM tree has **41**, and the 33 it is missing are the whole `Odoo::Ops::*` layer the specification's layer table says the extension consumes - including `Odoo::Ops::Guard`, **which IS the scoped mode.** Installing 0.01 would therefore give the engine a mapper with no scope guard: general mode only, which X4-b permits solely with the user's own credential, so the named-query mode this filing is built around would be unavailable. `Odoo/Transport.pm` itself is also absent. A **0.02 carrying both layers is a prerequisite of OP-25**, not a later tidy. |
| OB8 | One audit record per proxied call on the lazysite side: actor (lazysite account if any), Odoo login, model, method, mode, outcome state (answered / unanswered / refused / odoo-fault), never the payload and never the credential. Written the way connectors write theirs. |
| OB9 | Recorded in SECURITY.md as a new outbound interface (threat delta, controls, residual risk, verdict), as SM136 was for XMPP; named in FEATURES.md as the third egress kind after the guarded GET and the connector: *a per-user proxy to an operator-configured upstream*. |

## Authentication and the credential cookie (P2 Parts 2 and 3)

| Ref | Requirement |
| --- | --- |
| OA1 | Every strategy implements one contract: take user input, obtain a credential from Odoo, return what the cookie should carry plus the identity context (OA4). Everything downstream is strategy-independent. |
| OA2 | **Strategy: session.** POST db, login and password to Odoo's session-authenticate endpoint; the returned session identifier is what the cookie carries and is replayed as a Cookie header on each proxied call. Stated limits, in the docs rather than discovered: the password transits the extension (never logged, stored or echoed); a user with two-factor authentication cannot complete this flow. Suitable for internal tools on trusted networks. |
| OA3 | **Strategy: apikey.** The user generates a key in their own Odoo preferences and pastes it once. Preferred implementation: use the key ONCE at login to obtain a session, carry the session, discard the key. If the target Odoo version does not support that, carry the key and say so in the docs - a long-lived credential in a cookie is a materially different risk and must not be silently adopted. |
| OA4 | The credential cookie is httpOnly, Secure, SameSite; path-scoped to the app's own path; cleared on logout and when Odoo reports the session invalid. |
| OA5 | **Amplification, designed against:** with an httpOnly cookie and a same-origin proxy, any script injection on a page that can reach the cookie path can drive Odoo as the signed-in user without reading the cookie. Required from the start: a CSRF token on the lazysite leg for every state-changing proxied call (the manager-api pattern), the path scoping above, and a tight content-security-policy on app pages. |
| OA6 | A shared browser-side data module handles fetch, the CSRF token with one retry, and the re-authentication prompt. Every app page uses it; no page writes its own fetch logic. |

## Identity context (P2 Part 4 - the part that unlocks the rest)

| Ref | Requirement |
| --- | --- |
| OI1 | On successful authentication, fetch the user's Odoo identity once - uid, login, display name, group membership (xml ids where obtainable), company id and allowed company ids, lang, tz - and make it available to rendering. |
| OI2 | Carried in a SECOND cookie, distinct from the credential, HMAC-signed with the site secret and verified on every render. An unsigned identity cookie lets a user edit their own group membership and change what the server renders; a tampered one is rejected and the page renders as though unauthenticated. |
| OI3 | Short TTL (`odoo_identity_ttl`); refreshed transparently on the next proxied call after expiry. Groups and companies change in Odoo and the cookie will not know. |
| OI4 | **THE RULE, in the code comments and the docs:** identity context is for PRESENTATION ONLY, never for authorisation. Hiding a button from a non-manager is a convenience; the proxy still forwards the call if it is made, and Odoo is the thing that refuses it. Any code path that uses identity context to permit rather than to present is a defect. |
| OI5 | **The caching landmine, made impossible rather than documented:** lazysite caches rendered HTML. A page whose output varies by Odoo identity MUST NOT be served from a shared cache. Either mark such pages uncacheable or key the entry by identity, and make the unsafe case fail closed - a page that binds identity and forgets the flag must not leak. Engine note: [[SM857]] (d) already ruled that a gated page bypasses the cache and that a `mine` binding implies the same treatment; an identity binding is the third member of that set and should reuse the same mechanism, not add one. |

## MCP surface (P2 Part 6)

| Ref | Requirement |
| --- | --- |
| OM1 | An agent uses ITS OWN Odoo account, configured by the operator - never a human user's credential and never impersonation. Attribution in Odoo's audit trail stays truthful; the agent's Odoo permissions are what bound it. |
| OM2 | Tools follow the connector's naming and error conventions. The exact set is settled when the mapper spec is merged; at minimum: introspect models and fields, read, write, all within the agent's own permissions. |
| OM3 | A distinct `manage_odoo` capability, separate from `manage_content` and `manage_data`; writes audited on the lazysite side as well as Odoo's. Engine note: a new capability costs the map, the grid, `describe-capabilities`, both channel gates and the docs ([[SM857]] (g) priced this); the briefing asks for it deliberately and the cost is accepted here rather than discovered at build. |

## TT surface (P2 Part 7)

| Ref | Requirement |
| --- | --- |
| OT1 | Identity context exposed to templates under a single namespace: name for greeting, groups for showing or hiding sections, company for scoping, lang and tz for formatting. Variable naming obvious and documented on the extension's page. |
| OT2 | Every example in the docs demonstrates presentation use and none demonstrates authorisation use, so the pattern the next author copies is the safe one. |

# Reconciling the draft with the briefing

**P1's load-bearing rule was "Named queries only. No raw model, method or domain
passthrough to the browser, ever."** P2's general mode is passthrough by design,
and its scope control forbids an allowlist there. The two are reconcilable only
by naming the difference: **who holds the credential.**

- P1's client held an operator service account. With a shared credential, a
  caller who can name a model and a domain has an arbitrary-read primitive
  against the business system, reachable from a page - so the rule was right for
  that design and stays right for every service-account path (OM1).
- P2's proxy carries the signed-in user's own credential. Odoo's record rules
  and access rights bound the call exactly as they bound Odoo's own web client,
  and the audit trail names the person. Passthrough is then not a primitive
  lazysite grants; it is Odoo's own surface reached through a proxy.

So: OB3 (general mode) applies only to a call made with the user's own
credential; OB2 (scoped mode) is P1's named-query shape and is the default for a
purpose-built app; OM1 keeps P1's rule for agents. P1's "first useful queries"
(available quantity by product, lot and location; sales-order and picking state;
whether an order was validated since the last export) are the first scoped app.

**P1 said request-time, not the daemon.** Still true. The periodic-refresh idea
it superseded is a scheduler consumer and becomes natural once [[SM666]] phase 1
exists; neither is a reason to wait.

# The egress question (P3), and what the audit found (P4)

The briefing assumed "the 0.13.10 egress capability" would carry the outbound
leg. The release manager's follow-up corrected that: outbound HTTP is the
connector mechanism (0.13.5 to 0.13.9), and a connector holds an operator
credential shared across callers, which is the opposite of what required
outcome 2 needs. Three candidates were put, to be resolved at audit before Part
5 is built:

1. The proxy does its own HTTP as a distinct transport.
2. Connectors gain a per-user credential mode.
3. The proxy is exempted by design and documented as such.

## The finding

**There is no "one egress path" rule in the tree.** The phrase "the only way out
over HTTP" in FEATURES.md sat in the form-handler-types paragraph and meant
*among handlers*; it was reworded 2026-09-26. Four HTTP clients (`Lazysite::Fetch`,
`Manager::Connectors`, `Manager::Layouts`, `Manager::Domains`), SMTP and XMPP each
open their own connection; no lint pins any of them to a module; ADR 0009 (the
plugin contract) says nothing about the network beyond `owns.deps`.

**The rule that exists is about who may cause a call**, ruled by the release
manager 2026-09-03 and written into [[SM579]] ("How an egress call may be
invoked"): every outbound call, "regardless of what is at the other end", is one
of three sanctioned modes - scheduled, invoked by a logged-in user holding the
capability, or backing a public service with bounded input - and the engine
enforces the mode, the caller and the rate while the implementor bounds the
payload. This filing already bound itself to that rule on 2026-09-03 ("An Odoo
query is one of those calls. It takes SM579's modes, SM579's caps and SM579's
declaration").

**The guard is keyed on who chooses the destination.** `Lazysite::Fetch` refuses
loopback, RFC1918, link-local, multicast and CGNAT, is GET-only and carries no
credential, because *content* chooses its URL. Connectors permit private ranges
deliberately ([[SM790]]: "open BY DESIGN ... a service on this host is a
legitimate destination") because the *operator* chose the URL in the reserved
tree; their discipline is redirect refusal, an answer cap, a timeout, the mode
gate, a rate cap and an audit record. The Odoo URL is operator-configured, so
the SSRF guard was never the applicable rule and settled decision 2 ("Odoo on an
internal network") conflicts with nothing enforced.

**Connectors cannot carry the per-user leg as they stand.** They hold one
operator secret per connector in a named header; refuse any payload that is not
a flat hash of text ("never a file or a structure"); cap the answer at 64 KB and
land it in a data-table row; and send form fields or table rows by row map. A
JSON-RPC body is nested, the credential is per request from a cookie, the
response goes to the browser and is stored nowhere, and a `search_read` answer
can exceed 64 KB legitimately. Candidate 2 would not be a mode; it would be a
second transport with a different payload contract, credential model and answer
path, sharing only the name and the `may_call` gate. SM579's own boundary -
"every generalisation of it should be refused by default" - argues against it,
and the follow-up already said it "deserves its own SM".

## The ruling (X4, ruled 2026-09-28)

**RULED AS RECOMMENDED by the release manager, 2026-09-28**, all three questions
together. The recommendation is left standing below as the reasoning the ruling
absorbed rather than being replaced by a sentence saying "approved" - a ruling
that discards its own argument cannot be re-examined when something changes.
What was decided:

| | Ruled |
| --- | --- |
| **X4** | Candidate 1: the proxy does its own HTTP, **stated as mode 2 inside [[SM579]]'s policy, not beside it**. Which means SM579's invocation-mode policy has to become the shared thing it is not yet - today the three modes are connector-private (`$MODES` and `may_call` in `Lazysite::Manager::Connectors`). That generalisation is the first piece of work, and it is a prerequisite of this filing rather than part of it. |
| **X4-a** | **No plain `http://` to an RFC1918 Odoo.** `https://` to a private hostname - which the connector rule already permits - is enough, and is the natural reading of the briefing's "internal network". `http://` stays loopback-only, as OB6 says. |
| **X4-b** | **Yes**: the briefing's general mode supersedes this filing's original "no raw passthrough, ever", reconciled by naming the credential holder. The user's own credential means Odoo's own ACLs bound the call. A service account - Part 6, MCP - keeps the original rule. |

The reasoning, as recommended and now ruled:

**Candidate 1, stated as mode 2 INSIDE SM579's policy, not beside it.** The
proxy does its own HTTP and inherits SM579's enforceable controls by
construction: OB4 (mode 2 only), OB5 (timeout, rate cap, fault kinds), OB6 (the
connector's transport discipline as behaviour), OB8 (the audit record), OB9 (the
register entries). Candidate 3 would document an exemption from a rule the tree
does not have; candidate 1 with those rows is the same work with the true
rationale.

Two sub-questions ride with the decision:

- **X4-a.** May plain `http://` reach an RFC1918 Odoo, or is `https://` to a
  private hostname - which the connector rule already permits - enough? The
  briefing's "internal network" reads naturally as the latter.
- **X4-b.** Does the briefing's general mode supersede this filing's original "no
  raw passthrough, ever"? Recommended yes, reconciled as above by naming the
  credential holder.

The row was on `docs/decision-register.md` and is **deleted**, which is what that
register asks for: it carries what is open, not a history. The ruling is in this
filing's status-note and in the table at the top of this section.

# Engine notes from the audit (P4)

Things found against the code and the neighbouring trees while answering the
egress question, recorded so they are not rediscovered at build.

**OOM's transport IS the hardened one now - this note was true when written and
is not any more.** Re-measured 2026-09-28 against `oom`:
`Odoo::Transport::http_client` builds `HTTP::Tiny->new` with `max_redirect => 0`,
`verify_SSL => 1`, a named agent string and an optional `max_size` from
`max_response_bytes`; `refuse_by_policy` throws kind `refused` on any 3xx or an
oversized answer, by name rather than as a retryable transport failure, and
`JSONRPC` uses both. So most of OB6's discipline already lives inside OOM and
**the extension does not need to inject a transport to get it** - which removes a
piece of work this note had put on the build. What OB6 still has to own is the
part that is about the URL rather than the connection, and that is X4-a's
question. The other half of the original note stands unchanged:
**OA2's session strategy is not what OOM speaks**: OOM authenticates with
`common.authenticate(db, login, key)` and sends the key in every `execute_kw`
body on `/jsonrpc`. OA3's apikey strategy fits OOM; OA2 needs Odoo's
`/web/session/authenticate` and `/web/dataset/call_kw`, for which OOM has no
client. Whether the mapper rides on OOM for both strategies or only for apikey
is a mapper-spec question.

**Target Odoo version.** The Odoo workspace runs series 16 (the read-side
baseline OOM was proven on) and 18; OOM's test plan spans 16 to 20 and flags 19
for a change in RPC password-login policy and a new `/json/2` endpoint. Whether
`/web/session/authenticate` accepts an API key in place of a password (OA3's
preferred implementation) is a live probe, not a fact in either tree; plan for
OA3's fallback on 16 and 18 until probed, and record what was verified against
which series, as the briefing asks.

**Config key naming.** Extensions declare `config_schema` entries as
`{ key, label, type, default, required, show_when, note }` with types `text`,
`number`, `select`, `boolean`, `password`, `path`. The data extension prefixes
its keys (`db_source`, `db_descriptor_dir`) and lists them in `config_keys`;
OB1's `odoo_*` keys follow that style and fit the schema as written.
`odoo_strategies` is multi-valued; no existing extension has a multi-select
convention, so that is settled at build.

**Field descriptors.** The briefing asks whether the mapper's field descriptor
(type, required, readonly, selection values, relation, help) is close enough to
the data extension's table descriptors (`Lazysite::Data::Descriptor`, YAML, read
by YAML::PP) to share a rendering layer. It cannot be checked until the mapper
spec is filed; the comparison target is named here so the check is one step when
it is.

**A neighbouring drift, out of scope.** FEATURES.md and the fetch module's own
header list "remote layouts" among the guarded fetches, but `Manager::Layouts`
opens its own client to fixed GitHub hosts with no call to the guard. Harmless
today (constant host, slug validated); noted, not this filing's to fix.

# Required outcomes (P2 - the work is done when all are true and demonstrated)

1. A user authenticates with their own Odoo credentials through a lazysite page
   and can perform Odoo operations as themselves.
2. Every operation is attributed in Odoo to that user, not to a shared
   integration account.
3. An operation the user is not permitted to perform is refused by Odoo, and
   the refusal is distinguishable in the response from a transport failure.
4. No Odoo credential is stored anywhere on the lazysite server, in any file,
   table, log or cache. Demonstrated by inspection.
5. Odoo is reachable only from lazysite; a browser cannot and need not contact
   it directly.
6. The signed-in user's Odoo groups and company are available to TT at render
   time, and a page can vary its output by them.
7. A tampered identity cookie is rejected, and the page renders as though
   unauthenticated rather than with the claimed groups.
8. A page that varies by identity is never served from cache to a different
   user. Demonstrated with two concurrent sessions.
9. A state-changing call without a valid CSRF token is refused.
10. Session expiry produces a re-authentication prompt, not a silent failure or
    a generic error.
11. Both session and apikey strategies work against the target Odoo version,
    with the apikey strategy's credential-at-rest behaviour documented as
    implemented.
12. An agent over MCP performs Odoo work under its own Odoo identity, bounded by
    that account's permissions.
13. A scoped app cannot call outside its declared allowlist; the general
    interface is bounded only by Odoo permissions.

# Scope control (P2 - do NOT)

- Store credentials server-side under any circumstance, including "temporarily"
  or "for performance".
- Use identity context for authorisation decisions.
- Reimplement Odoo's access model, or filter results lazysite believes the user
  should not see - Odoo already did that.
- Apply an allowlist in general mode.
- Let an agent act as a human user.
- Build the generalised upstream-proxy abstraction. Structure the code so the
  proxy, cookie handling, CSRF and fault mapping sit apart from the
  Odoo-specific request shaping - the same mechanism (forward a call to an
  upstream carrying a per-user credential, store nothing) is not Odoo-specific
  and a second upstream should be an extraction, not a rewrite - but leave the
  seam visible and take the extraction when a second upstream exists.
- Implement OAuth here - it is its own extension when the driver is SSO across
  systems.
- Change lazysite core, except where the outbound HTTP leg genuinely requires it
  - report before doing so. (The audit's answer: the leg needs no core change
  now that X4 is ruled as recommended; OB9's register entries and OI5's cache
  rule touch core surfaces that already exist for this purpose. The one change
  outside this extension is SM579's policy becoming shared, which the ruling
  requires and which belongs to SM579.)

# Verification pointers (P2)

- Two concurrent browser sessions as different Odoo users against an
  identity-varying page: each sees only their own rendering, cold and warm
  cache.
- Identity cookie with an edited group list: rejected, renders unauthenticated.
- A method the test user lacks rights for: Odoo refuses, kind distinguishes it
  from a network error.
- grep the filesystem, tables and logs after a full session for any credential
  material: nothing found.
- Odoo blocked at the firewall from the browser's network, everything still
  works.
- Expired session mid-transaction: re-auth prompt, then the action completes
  without data loss.
- A scoped app calling a model outside its allowlist: refused by lazysite
  before the call leaves.
- Engine additions: a 3xx from the upstream is recorded as a refusal and the
  credential is not re-sent; an answer over the cap is refused by name; the
  audit record for a call carries no payload field and no credential.

# The mapper specification, FILED 2026-10-01

The seam this filing held open is closed. The specification was written in the OOM
tree from what has been built and exercised against Odoo rather than in advance of
it, and the release manager directed on 2026-10-01 that it be filed here.

**Provenance, and the reason it is recorded rather than trusted:**

| | |
| --- | --- |
| Source | `/srv/projects/odoo/oom/docs/MAPPER-SPEC.md` |
| Written | 2026-09-28, status DRAFT, "growing with use" |
| sha256 at filing | `d6e8c731b19654e972d7c520dd1ccd4bc62cb549e91c3ef2ff0606ad6929ed7c` |
| Living copy | stays in the OOM tree - that project owns it |
| Drift gate | `t/lint/207-the-filed-mapper-spec-matches-its-source.t` |

A second copy of a document that is still being edited elsewhere is how two
descriptions of one thing come to disagree, and this filing has already been stale
twice (see *Sequencing*). So the hash is recorded and a lint compares it whenever
the OOM tree is readable, skipping where it is not - the shape `t/lint/89` uses for
the field-practice briefing, for the same reason.

**Every claim in the spec says what it rests on**, and that grading is the most
useful thing in it: **tested** (offline suite against a fake Odoo), **source** (read
from the Odoo 16.0 source), **live** (verified against a named instance and series),
or **design** (decided, not yet exercised).

## 1. Layers

| Layer | Modules | Responsibility |
| --- | --- | --- |
| Mapper | `Odoo::Client`, `Model`, `Record(Set)`, `Commands`, `Transport::*`, `Error` | RPC, introspection, read/write, x2many grammar, fault classes |
| Operations | `Odoo::Ops::*` | named operations, scope guard, profiles, plan/apply/journal/revert, audit |
| Function packs | `Odoo::Ops::CRM::*`, `Odoo::Ops::Comms::*` | the business operations |

The extension consumes the mapper **and the operations layer** as the
`libodoo-oom-perl` package (OB7), never a copy. **That is a requirement on the
package, and the package that exists does not meet it** - see OB7 below.

## 2. Transport discipline (OB6) - tested

- No redirect is followed; a 3xx dies as kind `refused` (code `redirect`) naming the
  target. HTTP::Tiny follows a 303 even on POST by default; switched off.
- `max_response_bytes` caps an answer; over it dies `refused` (`oversize`), not
  retried.
- TLS verification on. Only kind `transport` is retried.

This is OB6 satisfied in the layer below the engine, which is why OB6's engine-side
work came off the build on 2026-09-28.

## 3. Fault kinds (OB5) - tested, wire shapes from source

`Odoo::Error->fault_category`: `access` (AccessError), `credential` (AccessDenied),
`session` (SessionExpiredException), `validation` (ValidationError, UserError),
`missing` (MissingError), `other`. JSON-RPC carries the class in `error.data.name`;
**XML-RPC only in the traceback, from which it is recovered.** Plus kinds
`transport`, `refused`, `config`, `usage`.

## 4. Named operations and scope (OB2, OM2) - tested

An operation declares `op_name`, `params` (typed, validated, unknown names
refused), and `read_scope` / `write_scope` as `{model => [methods]}`.
`Odoo::Ops::Guard` wraps the transport and refuses any `execute_kw` outside the
running operation's scope **before it leaves**. Base scope is `common.*`,
`fields_get` on any model, `res.users.read`.

**This is SM747's scoped mode, and it already exists.** A named query is an
operation with a declared scope and bound params. General mode (OB3) is the
*absence* of the guard, and applies only with the user's own credential - which is
exactly the division X4-b ruled.

## 5. Plan / apply - tested

Write operations only plan. A plan is JSON: changes (create, write, unlink, call,
custom, skip, hold) each in a named bucket with the before-image it saw; buckets sum
to the input; sealed by fingerprint; bound to an instance; `applied: 0`. Apply
refuses read-only configs, other instances, edited plans, re-applies and stale
before-images; reads every write back; journals each change as it happens;
`applied: 1`. Revert is itself a plan.

**A lazysite app presents the plan's buckets as the preview and calls apply on
confirm** - so the preview-then-confirm shape the briefing asked for is the mapper's
own, not something the engine has to invent.

## 6. Audit (OB8) - tested

One record per RPC call, fixed fields only: `ts actor login service model method op
outcome fault_category ms`. **The sink refuses any other key**, so a payload or a
credential cannot be added by accident. OM3's lazysite-side audit sits beside this,
not instead of it.

## 7. Credential strategies (OA1) - design, and ONE PIECE OF NEW WORK

`Odoo::Ops::Credential->resolve($config)` returns what the client needs. `file` (an
API key file, mode 600 enforced) ships. **`session` and `cookie` are reserved names
that REFUSE** - left for the extension to implement.

**The consequence for Parts 2 and 3 of the briefing, which is new:** OOM speaks
`common.authenticate` + `execute_kw`. The per-user credential cookie needs
`/web/session/authenticate` + `/web/dataset/call_kw` - **a transport OOM does not
have.** So the engine's own work includes that transport, or OOM gains it first. It
is not a line of configuration, and it was not visible before the spec was filed.

## 8. Field descriptors - tested in shape, live pending

`Profile->descriptor($model, $field)` returns the server's metadata under the
logical name: `type string help required readonly store relation relation_field
selection`, plus `name` (physical).

The seam this filing asked about is **still open and now precisely stated**:
comparison with lazysite's data-extension table descriptors has not been done, so
whether the two can share a rendering layer (widget per type, generated forms) is
unanswered. The spec says so itself rather than implying a shape.

## 9. Series - tested in mechanism, live pending

Logical-to-physical profiles per pack and series, validated against live
`fields_get`; nearest-lower fallback with a warning. Behaviour beyond names (for
instance sending mail) dispatches per series and **refuses on an unprobed one** -
which is the four-state discipline arriving from another project.

| Behaviour | 16 | 17 | 18 | 19 | 20 |
| --- | --- | --- | --- | --- | --- |
| crm profile | live 2026-09-28 (16.0-20250909): 42/42 fields, restricted CRM user | - | - | - | - |
| `read_group` row count key `<field>_count` | live (crm.inspect) | - | - | - | - |
| API key minted over the web session (make_key, identitycheck, run_check), then password spent | live 2026-09-28 | - | - | - | - |
| send via composer (mass_mail on one lead) | source | - | - | - | - |

**Only series 16 is probed at all**, and only on one instance. Every other column is
empty, and the mechanism refuses rather than guesses - so an 0.15.x extension is a
16-series extension until somebody probes another.

## 10. Onchange and x2many

Writes **never invoke onchange** (a mapper decision, recorded in OOM's
`docs/USAGE.md`): the tools set only the stored fields they name, so **a created
lead is what the API creates, not what a form would.** x2many values go through
`Odoo::Commands`; operations add tags by `(4, id)` and never replace a set unless
told to (`on_match: overwrite`).

This filing's seam said that whatever the spec decided, **the docs must be explicit
about it.** That obligation is now concrete and belongs in the extension's own
documentation: a record created through this path can differ from one a person
creates in Odoo's UI, and an operator who does not know that will eventually find it
out from a workflow that did not fire.

# What filing the spec closed, and what it did not

| Seam this filing held open | State |
| --- | --- |
| The proxy's request-shaping layer (OB2, OB3) | **CLOSED.** Section 4: the Guard is the scoped mode and its absence is general mode, which is the division X4-b already ruled |
| Onchange and x2many (OM2's write behaviour) | **CLOSED**, section 10 - with a documentation obligation attached rather than a free choice |
| Which strategies ride on OOM | **CLOSED, and it found work**: `file` ships, `session`/`cookie` refuse, and the session transport does not exist (section 7) |
| Field descriptors sharing a rendering layer with the data extension | **STILL OPEN.** The descriptor shape is tested; the comparison has not been made |
| The MCP tool set (OM2) | **PARTLY.** The spec settles the *vocabulary* - a tool is a named operation with a declared scope - and the function packs name 12 CRM operations and 2 Comms ones. WHICH of them become MCP tools is a selection this filing still owes, and OM1's agent-own-account rule bounds it |

**The spec's own open list, carried here rather than left in another tree:**

1. live verification on the v16 CRM account (pending);
2. the session transport for OA2 - which is the new work in section 7;
3. descriptor comparison with the data extension.

# Sequencing

Scheduled 2026-09-28 at the release manager's direction, after the egress policy
it sits inside. Four gates stood in front of it; three are down, and the last is not
engineering's.

| Gate | State |
| --- | --- |
| X4 and its sub-questions ruled | **DONE 2026-09-28**, as recommended |
| SM579's invocation-mode policy becomes shared, so the proxy can be mode 2 *inside* it | **DONE, AND RELEASED.** `lib/Lazysite/Egress.pm` landed in 0.15.1 - `@MODES` and `may_invoke`, proved equivalent over 960 combinations, and its own comments already name `proxy` as a caller. This row said "the piece being built first" for three days after it was built, which is why the drift gate above now exists |
| The mapper specification filed and merged here | **DONE 2026-10-01.** Filed above with its source hash. It closed three seams, left two open and **found one new piece of work** - the session transport OOM does not have (section 7) |
| OOM reachable by this engine (OB7) | **STILL OPEN, and it is the only gate left - but it is a DECISION, not a packaging task.** `perl -MOdoo::Client -e1` fails on this host. This row first said a 0.02 deb had to be built; the release manager's direction of 2026-10-01 corrects that - OOM is under test and will have consumers beyond lazysite, so its delivery shape belongs to all of them. What survives is the requirement on CONTENT: whatever is delivered carries the `Odoo::Ops::*` layer, or there is no scoped mode. See *The direction, 2026-10-01*. OP-25 |

The first scoped app is the stock-corrections portal's live facts (P1).
