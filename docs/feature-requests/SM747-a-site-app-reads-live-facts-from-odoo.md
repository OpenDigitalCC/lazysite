---
id: SM747
title: "SM747: the Odoo extension - a person uses Odoo through a lazysite page as themselves"
subtitle: "One filing for the whole Odoo extension: per-user authentication carried in a cookie, a signed identity context for rendering, a proxy transport in two modes, an MCP surface under the agent's own Odoo account, and the object mapper to be merged when its specification arrives. Consolidated 2026-09-26 from the odoo-bridge draft, the release manager's authentication briefing and its egress follow-up, and the engine's audit. Queued for a future release; nothing here is built."
brand: plain
standard-margins: true
status: candidate
status-note: "RULED 2026-10-12: a connection user (a site Odoo account, its credential stored like a connector secret) runs named operations for pages, MCP and backend work; a site user's own sign-in waits on OOM's session transport; Odoo descriptors share data-table rendering; every operation is an MCP tool. Re-planned: A, CU, R, E unblocked. Filed to OOM 10-12: the session transport, the Ops layer in the deb. Q1-Q3 RULED 10-12: a public binding may apply unattended under the engine's controls; MCP uses the default or a per-grant account; the type mapping is OOM's (options filed). RE-FILED 2026-10-13 against OOM 0.09: OOM built the session transport in 0.03 (live on Odoo 16 and 19), the Ops layer and the portable type in 0.02, and in 0.09 the run registry with its approval gate, revert and resume, core.user, core.attach and core.fetch, a JSON-2 transport for 19 and a doctor, all as debs in /srv/projects/packages; B, C and D are no longer waiting on OOM, and whether to build them is the release manager's (B-Q1)."
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

# Ruled 2026-10-12

The release manager, in their words:

> "the extension can hold odoo specific data such as a connection user, as well as a
> site user specifying their own. the connection user is set on odoo with permissions
> as required by the user, which allows some backend activities, without the user
> logging in. the oom deb will be updated so assume that carries what you need, and if
> not, file to the oom inbox. wait for OOM to gain the session transport, and ensure
> this request also filed. Odoo field descriptors can share lazysite's data-table
> rendering. All operations should also be mcp tools."

## What it decides

| Ref | Decided |
| --- | --- |
| R1 | **A connection user.** The extension holds a site-level Odoo account: a login and its API key. Its rights are set **in Odoo** by whoever administers Odoo, as the site's work needs; lazysite grants it nothing and narrows nothing Odoo allows. It lets the extension do backend work - a scheduled job, a public form, a page a lazysite user opens - with nobody signed in to Odoo. |
| R2 | **A site user may specify their own credential** - the per-user path of Parts 2 to 4. It **waited for OOM's session transport, which shipped 2026-10-13 (0.03); building it is B-Q1**; OA3's fallback (the key itself carried in the cookie) is not taken. The request is filed (see *Where the 2026-10-12 requests were filed*). |
| R3 | **OOM is delivered as the `libodoo-oom-perl` deb**, which will be updated to carry what the extension needs; a gap is filed to OOM's inbox. This answers stage 0's delivery-shape question (OP-25) and OB7. |
| R4 | **Odoo field descriptors share lazysite's data-table rendering.** The seam this filing held open since 2026-09-26 is closed. |
| R5 | **Every operation is also an MCP tool.** The open selection under OM2 is closed: all of them. |

## What it changes against this filing's text

Until this ruling, outcome 2, outcome 4, OB1, settled decision 1 and the first
scope-control rule together forbade a shared Odoo account and any stored Odoo
credential on the user-facing path, and the 2026-10-02 plan read them, correctly, as
"there is no cheap read-first slice". **R1 permits exactly that account and its stored
credential.** The rows below are amended as stated; each carries a pointer back here.
Nothing else in the requirements changes.

| Row | Said | Now, under R1 to R5 |
| --- | --- | --- |
| Settled decision 1 | Lazysite stores NO Odoo credential server-side, ever | No **user's** Odoo credential is stored server-side, ever - unchanged for the per-user path. The **connection user's** credential is the one stored credential, on the terms in OB1 |
| OB1 | No shared service account and no stored credential for the user-facing path; a service account only for MCP, mode 600 | The extension's config may hold a connection user: `odoo_login` and an API key. **Stored as connector secrets are** (`Manager::Connectors`): the key in a separate 0600 file, written on its own, never listed, never returned by any action or tool, never logged; `has_secret` answers 1, 0, or null for "cannot tell". An API key, not a password: OOM refuses a password in its config (`Odoo/Ops/Config.pm:68`) and its `file` strategy enforces mode 600 on the key file (`Odoo/Ops/Credential.pm:48-57`) |
| OB3, X4-b | General mode applies only with the user's own credential | **Unchanged, and now load-bearing.** The connection user is a shared credential, so it runs **scoped mode only** - named operations behind `Odoo::Ops::Guard`, from every surface. P1's "no raw passthrough, ever" holds for it in full |
| OB4 | Mode 2 only; no scheduled and no public mode for the per-user proxy | Unchanged for the per-user proxy. The connection-user path takes [[SM579]]'s three modes, **declared per binding**: mode 2 (a lazysite user holding the capability), mode 1 (scheduled) and mode 3 (public, bounded input) - R1's "backend activities, without the user logging in" |
| OB8 | Actor (lazysite account if any), Odoo login, model, method, mode, outcome | For a connection-user call the actor is **the lazysite account that triggered it** (or the mode and binding, for a scheduled or public call) and the Odoo login is the connection user's. OOM's own audit carries the same actor: `Odoo::Ops::Context` takes `actor` (`Context.pm:65`) and the Guard writes it on every record (`Guard.pm:128`) |
| Outcome 2 | Every operation attributed in Odoo to that user, not to a shared integration account | Per-user path: unchanged. Connection-user path: **attributed in Odoo to the connection user**, and in lazysite's audit to the lazysite account (or mode) that triggered it. The two records together are the truthful trail |
| Outcome 4 | No Odoo credential stored anywhere on the lazysite server | No **user's** Odoo credential stored anywhere - unchanged, demonstrated by inspection. The connection user's key exists in exactly one place, the extension's 0600 secret file, and the inspection extends to proving it is in no table, log, cache, page, response or audit record |
| OM1 | An agent uses its own Odoo account, configured by the operator | **Met by the connection user**: an operator-configured, non-human account; never a person's credential, never impersonation. Whether MCP gets an account of its own is Q2 below - **ruled 2026-10-12: the default or a per-grant account** |
| OM2 | The tool set is settled when the mapper spec is merged; at minimum introspect, read, write | **All operations** (R5): every operation OOM's `Odoo::Ops::Registry` lists becomes a tool, generated from its `op_name`, `summary` and `params`, with no per-operation engine code. 16 today - 12 CRM, 2 Comms and 2 Core (`core.check`, `core.rights`). A write operation's tool returns its plan; one apply tool applies a plan by fingerprint |
| Scope control, first rule | Store credentials server-side under any circumstance | Applies to **user** credentials. The connection user is the ruled exception, on OB1's terms and no others |
| Field descriptors (*Engine notes*, spec section 8) | Whether they can share the data extension's rendering is unanswered | **Closed by R4**: they render through the data extension's table rendering (`Lazysite::Data::Descriptor`'s types - text, integer, decimal, boolean, date, datetime, enum; `lib/Lazysite/Data/Descriptor.pm`). Where the Odoo-type-to-lazysite-type mapping lives is Q3 |

Outcome 12 and OM3 stand as written; the connection user satisfies the first.

## Questions the ruling leaves (none blocks slice A or CU's read half)

> **All three RULED 2026-10-12** - see *Ruled 2026-10-12 (Q1-Q3)* below. The
> questions and their recommendations are kept as the record the rulings answered.

- **Q1. May a scheduled or public binding apply a write plan with nobody to confirm
  it?** Mode 2 previews the plan's buckets and applies on confirm. Modes 1 and 3 have
  no one at the page. Recommended: only where the binding declares it per operation,
  the plan still saved and journalled; plan-only otherwise.
- **Q2. Does MCP use the pages' connection user, or one of its own?** One account is
  enough for R1 and OM1; a second makes Odoo's own trail tell agent work from page
  work. Recommended: one now, a second as a configuration addition when somebody
  needs the separation.
- **Q3. Where the type mapping lives.** Mapping Odoo's field types (`many2one`,
  `monetary`, `selection` ...) onto the data extension's seven is Odoo knowledge,
  which *The rule that keeps it general-purpose* puts in OOM. Recommended: OOM hands
  the descriptor with a portable type beside the Odoo one (asked, not blocking, in the
  deb request); failing that, one mapping table in the extension, named by the
  boundary lint.

## The status-note before this ruling

It recorded the consolidation of 2026-09-26, X4's ruling of 2026-09-28, the
prerequisite that landed in 0.15.1 (`Lazysite::Egress`), the mapper specification
filed on 2026-10-01 with its hash and `t/lint/207`, the two seams that filing left
open (descriptors, the MCP selection), the session transport OOM does not have, and
the 0.01 deb's 8 modules of 41. All of it is in the body below; R3 to R5 close the
three that were open.

# Ruled 2026-10-12 (Q1-Q3)

The release manager, in their words:

> **Q1** (may a scheduled or public binding apply a write plan with nobody to
> confirm): "use case includes ecommerce, where a visitor adds to basket and this
> creates sales quotation as basket. there may be other functions that an anonymous
> visitor uses, and determined by the internal odoo user to control what this may
> do."
>
> **Q2** (MCP account): "MCP will use the default or specified account. the default
> user is likely to be more restrictive, so having an own user may open up more
> functionality."
>
> **Q3** (where the Odoo-field-type to lazysite-type mapping lives): "open to
> recommendations, maybe put options to oom inbox, and it can be worked through
> there."

## What they decide

| Ref | Decided |
| --- | --- |
| Q1 | **A public (or scheduled) binding may APPLY a named write operation through the connection user with nobody confirming.** What it may do is bounded by two things and only two: (1) the connection user's rights, set in Odoo by whoever administers Odoo; (2) which named operations the page binds - OOM's Guard refuses any call outside the bound operation's declared scope before it leaves. Lazysite narrows nothing Odoo allows and grants nothing Odoo refuses. |
| Q2 | **MCP uses the connection user by default, or an Odoo account configured for that MCP grant**, its key stored as the connection user's is (0600, written alone, never returned, `has_secret` three-state), one per grant. Slice E. |
| Q3 | **The mapping is OOM's to settle, worked through in its inbox.** Filed as an options paper: `/srv/projects/odoo/oom/inbox/2026-10-12-field-type-mapping-options-for-lazysite.md`. Slice R is built against an interface that takes the PORTABLE type from OOM's descriptor when present and otherwise REFUSES to render the field, naming it - so lazysite holds no mapping whichever option OOM takes, and t/lint/240 keeps it that way. |

## The design Q1 requires of the engine

An anonymous write path into an ERP is the sharpest thing this extension adds, so the
controls are the engine's on every public apply, whatever the operation:

| Control | What the engine does |
| --- | --- |
| Opt-in, per binding | A binding permits `public` only when it says so (SM579's opt-in); a write binding declares `apply: immediate` to apply in the same request, otherwise its plan waits for a confirm. The gate is `Lazysite::Egress`, as for a connector. |
| Rate caps | Two, counted from the call record and decided by `Egress::within_caps`, most specific first: **per visitor per hour** and **per binding per hour**. A cap whose count cannot be taken refuses (an unreadable record is not zero). This is what stands between a script and a flood of quotations. |
| CSRF on the page's POST | A public POST carries a token bound to the visitor's key (HMAC under the extension's own secret); a signed-in POST carries the manager-api session token. The visitor cookie is `HttpOnly; Secure; SameSite=Strict`, so a cross-site POST arrives without it and cannot name a basket. |
| Input validation by the operation's declared parameters | Only the parameters the binding MAPS from input can come from input; each is checked against the operation's own declaration (type, required) before OOM is called, and an unknown or unmapped name is refused by name. Fixed parameters (`fixed:`) and the visitor parameter cannot be overridden by anything the request carries. |
| The visitor's own basket, and nobody else's | A visitor key is 256 random bits minted SERVER-SIDE and signed, so a key the server did not mint is refused. It reaches the operation only through the binding's declared `visitor_param`; a plan is stored against the key that made it and only that key may apply it; plan ids are unguessable. A visitor can therefore neither name, read nor alter another visitor's basket or quotation. |
| Audit naming the visitor | OB8's record names the actor as `visitor`, a hash of the visitor key (never the key, which is a bearer secret), the IP, the binding, the operation, the mode and the outcome; OOM's own audit carries the same actor on every RPC record. |

What the operation pack does with the visitor key - which Odoo record holds a basket,
how a basket becomes a quotation - is the pack's, per *The rule that keeps it
general-purpose*.

## What they change against this filing's text

| Row | Now |
| --- | --- |
| OB4 (amended 2026-10-12 R1) | **Q1:** a binding's `public` and `scheduled` modes may apply a write operation unattended when the binding declares `apply: immediate`, under the controls above. |
| OB5 | The per-identity rate cap is **per visitor key** on the public path and per lazysite account on the authenticated path. |
| OB8 (amended R1) | **Q1:** for a public call the actor is `visitor` with the visitor-key hash and the IP. |
| OM1 (amended R1) | **Q2:** the connection user by default, or an account configured for the MCP grant. |
| Field descriptors (closed by R4) | **Q3:** the type comes from OOM as a portable type; lazysite refuses a field without one. Options filed to OOM. |
| Outcome 9 | Holds on the public path too: a state-changing public call without a valid visitor-bound token is refused. |

# Built

Stacked branches from n470, each with its tests and a sabotage run (every guard
below was broken on purpose and its test went red; backups under
`tmp/sab-bak/sm747/`, restored and compared). OOM is loaded from its tree for the
tests (`t/lib/OdooTest.pm`, `LAZYSITE_OOM_LIB`), which says 0.01: a test that needs
OOM to run raises `$Odoo::Ops::VERSION` to the 0.02 the deb will carry and says so;
the refusal of 0.01 is tested without it. (The tree no longer says 0.01: it says 0.09 since
2026-10-13 (0.06 by the afternoon), so t/unit/odoo/04 and 05, which tested that refusal against it, fail on main;
branch n576 stands up an Odoo::Ops of its own that says 0.01.) No test reaches a network: OOM's
`Context` takes an injected transport, and the fake Odoo is OOM's own test double.

## Slice A - built 2026-10-12 (n471)

| Row | What | Where |
| --- | --- | --- |
| OB7, R3 | The extension, `plugins/odoo.pl`: a contract extension (born off), its config keys, and `owns.deps` = `Odoo::Ops (libodoo-oom-perl >= 0.02)`. The dep grammar gained `(package >= version)` (`Lazysite::Plugins::Owns::parse_dep`), read by the validator and by the enable path, which now refuses a module that loads but is older and names the declared package rather than one guessed from the module name (the guess was `libodoo-ops-perl`, which does not exist). At run time `Lazysite::Odoo::oom_check` refuses by the same name | `plugins/odoo.pl`, `lib/Lazysite/Plugins/Owns.pm`, `lib/Lazysite/Manager/Plugins.pm` (`_missing_deps`), `lib/Lazysite/Odoo.pm`; t/unit/odoo/04, 05 |
| OB1 | The connection in the extension's config (`lazysite/odoo.conf`): `odoo_url`, `odoo_db`, `odoo_login`, `odoo_timeout` (30), `odoo_max_kb` (2048), `odoo_allow_writes` (off), `odoo_packs` (extra operation-pack namespaces). Read and checked once, by `connection()` | `Lazysite::Odoo::connection`; t/unit/odoo/01 |
| X4-a, OB6 | https:// to any host; http:// to loopback only; plain http:// to an RFC1918 address refused in its own sentence, naming the remedy (https:// to the private hostname); a user or password in the URL refused | `check_url`; t/unit/odoo/01 |
| OB5 | OOM's kinds and Odoo's fault categories mapped to `{ ok: 0, kind, error }`: `session-expired`, `invalid-credential`, `odoo-access-refused`, `transport-failure`, plus `odoo-validation`, `odoo-missing`, `odoo-fault`, `scope-refused`, `read-only`, `stale`, `applied`, `edited`, `refused`, `config`, `invalid`, `internal`. The text is logged, never returned | `fault`, `outcome_of`; t/unit/odoo/02 |
| OB8 | One record per call in `lazysite/odoo/calls.jsonl` (0660), fixed fields `at call_id actor visitor ip login binding operation mode phase outcome kind ms`; the sink refuses any other key; one line in the shared audit trail (`odoo-call`) | `record_call`, `read_calls`; t/unit/odoo/03 |
| OB4, X4 | The mode gate is `Lazysite::Egress::may_invoke`, and `gate()` asks, in order: who (mode, callers), the extension switch, OOM present and new enough, the connection. Every refusal is a row | `may_call`, `gate`; t/unit/odoo/04 |
| *The rule that keeps it general-purpose* | **The boundary lint**: no RPC method or endpoint, ORM method name, dotted Odoo model name, Odoo field type or exception class in any functional file (comments and POD excepted, tests out of scope) | `t/lint/240-lazysite-holds-no-odoo-knowledge.t` |

Decisions taken in A, each from the filing's own text:

- **The endpoint.** The slice table says "endpoint config as a new handler type";
  OB1 and R1 put the connection, one per site, in the extension's config. Both are
  kept: the connection is the extension's, and the handler type `odoo` (slice CU) is
  how a form, the schedule or a page reaches it, naming an operation. Repeating a URL
  and a credential on every handler would be several copies of one connection.
- **No `storage` declared.** `lazysite/odoo/` will hold the connection user's key and
  plans carrying Odoo's records; a site package carries declared storage to another
  site, and neither belongs there.
- **The override capability is `manage_connectors`** until slice E brings
  `manage_odoo` (OM3), which the plan places in E: it is the capability that already
  governs where site data is sent and who sets a destination's secret.
- **The CHANGELOG key is `odoo-extension`, not SM747.** (Applies to every slice.) t/lint/75 reads SM747 as
  already shipped: c53a7143 ("the mapper specification filed") landed
  `t/lint/207` under an SM747 subject in a tagged release whose section has no
  SM747 bullet, so an Unreleased `- SM747` entry reads as stranded work. The
  entries name SM747 in their titles instead.

## Slice CU, the engine - built 2026-10-12 (n472)

| Row | What | Where |
| --- | --- | --- |
| OB1 (R1) | **The connection user's key**: one file per account under `lazysite/odoo/keys/`, written alone through a 077 umask and renamed into place (0600 from the moment it exists), never returned or logged; `has_key` answers 1, 0, or undef when the file exists and cannot be read. OOM reads it through its own `file` strategy, so OOM's mode check applies too. Outcome 4's inspection: after a full call the key is in that file and in no other file under the site | `Lazysite::Odoo::Secret`; t/unit/odoo/06 |
| R1 | **An OOM context per call**, built in memory, carrying the key, the connection, `allow_writes` and the ACTOR (`account:<name>`, `visitor:<hash>`, `scheduled`), which OOM's Guard writes on every RPC record. One attempt (`retries => [0]`): OOM's default ladder sleeps up to 22 s, right for a batch and wrong for a waiting visitor | `Lazysite::Odoo::context`; t/unit/odoo/09, 10 |
| OM2 seam | **Operations through OOM's registry**: OOM's packs plus `odoo_packs`, by namespace | `registry`, `operation_class` |
| OB2, SM579 | **The binding is a handler of type `odoo`**: `operation`, `params` (`field=parameter` - the only names a request may set), `fixed` (the operator's, never overridable), `visitor_param` (the server's key, never input), `modes`, `callers`, `apply` (`confirm` or `immediate`), `rate_per_visitor_hour` (20), `rate_per_hour` (200). Saving it checks it against the operation's own declaration when OOM can be asked (unvalidated is not invalid otherwise). Configured under `manage_connectors` until E | `lib/Lazysite/Handlers.pm`, `Lazysite::Odoo::Binding`; t/unit/odoo/08, 13 |
| Q1 | **Parameter injection**: a request feeds only `str`, `int` or `bool` parameters, each checked against the declared type, 1,000 characters at most, no control characters; a `json` (domain), `list` or `path` parameter can only be fixed, and a `path` cannot be set at all | `Binding::check_against`, `assemble`; t/unit/odoo/08 |
| Q1 | **The visitor key**: 256 bits minted server-side, carried `HttpOnly; SameSite=Strict` and signed under the extension's own secret (`lazysite/odoo/visitor.secret`, 0600); a key the server did not mint names nobody; the CSRF token is an HMAC of the key; records carry a hash of it | `Lazysite::Odoo::Visitor`; t/unit/odoo/07, 10 |
| OB4, Q1 | **The call**: `Lazysite::Odoo::call` - the one function that sends - asks, in order, the gate (slice A), the key, the operation, the binding against the operation, the parameters, the caps; then a read returns its report and a write returns its plan's preview (buckets, and each change's bucket and action - never values or before-images) or, for `apply: immediate`, applies it in the same request | `call`; t/unit/odoo/09, 10 |
| Q1, OB5 | **The caps**: per visitor (or account) per hour and per binding per hour, decided by `Egress::within_caps` from a rolling one-hour record taken under a lock; the slot is taken before the call, so attempts count whether Odoo accepts them or not, and a record that cannot be read refuses | `_take_cap`; t/unit/odoo/11 |
| A + CU | **Plans in a private store**: `lazysite/odoo/plans/<128-bit id>/` holds the plan, its owner and, once applied, OOM's journal and audit. `confirm` applies a plan only for the account or visitor that made it (anyone else gets exactly "not found"), within an hour, through the binding as it stands now; OOM's refusals arrive as `applied` (replay), `stale`, `edited`, `read-only`. Pruned after 7 days | `confirm`; t/unit/odoo/10, 12 |
| SM842 | **A form and the timer run a binding** as `public` and `scheduled`, as they run a connector; a binding needing a visitor key, or a write waiting for a confirm, is refused there by name | `Handlers::_to_odoo`; t/unit/odoo/13 |
| SM670 | The Odoo kinds have statuses in `%REFUSAL_STATUS` (Odoo answering badly is 502; Odoo refusing the operation 403; a plan that no longer fits 409; expired 410) | `lib/Lazysite/Manager/Common.pm` |

Decisions taken in CU, from the rulings and the filing:

- **A form is public and the timer scheduled**, exactly as a connector handler is
  told (SM842's precedent), and neither carries a visitor or a confirmer.
- **The preview carries no values.** A plan holds Odoo's records as the operation saw
  them; "present the plan's buckets" (section 5) is what a page is given.
- **Found while building, not this filing's to fix (reported):** `Connectors::sweep` initialises
  `my ( @keep, $expired, $unanswered ) = ( (), 0, 0 )`, so the array swallows both
  zeros and a sweep that expires nothing reports `expired: null`. The same shape was
  written here first and caught by t/unit/odoo/06.

### OOM's approval gate - found 2026-10-13, built (n585)

On 2026-10-13 (OOM's run registry, `Odoo::Ops::Runs`, merged 17:35) OOM's `Runner->apply`
began to refuse a plan nobody had approved (`unapproved`, `approval-stale`), unless the
config says `approval = none`, which OOM describes as for tests and trusted batches.
Every lazysite apply - a confirm, and an `apply: immediate` binding - was then refused
(`refused`, "the call was refused before Odoo answered"), and so were
t/unit/odoo/09 to 12 and 17 against OOM's tree.

**Decision taken** (not settled by the rulings, taken because the alternative is the
safer door left open): the approval is the act lazysite already has. A confirm is the
approval of the account or visitor that made the plan (the owner, who alone can
confirm), and `apply: immediate` is the operator's standing approval of that one
operation, given when they saved the binding. The engine records it with
`Odoo::Ops::Runs->approve_plan` - by whom, a note, the plan's own fingerprint -
immediately before the apply, and **does not set `approval = none`**: OOM's gate stays
on for anything lazysite did not approve. A plan already applied is not approved again
(OOM refuses the replay by name, `applied`). An OOM without the registry has no gate and
nothing is recorded. t/unit/odoo/40.

**Asked of the release manager, if the other reading is wanted:** that a confirm is not
enough and a second, separate approval step is. That is a design change to Q1's
"nobody confirming" cases and is not taken here.

## Slice CU, the surfaces - built 2026-10-12 (n473)

| Row | What | Where |
| --- | --- | --- |
| OA5, outcome 9, Q1 | **The page endpoint, `lazysite-odoo.pl`** (declared in `owns.endpoints`, shipped in the deb, classified as a core CGI). `GET ?csrf=1` gives the visitor token - minting the visitor cookie if there is none - and, for a signed-in account, the session token; `GET ?binding=` runs a READ binding (a write sent as a GET is 405); `POST {binding, params}` runs one; `POST {plan, confirm}` applies a plan this caller made. It verifies its own caller (SM411). A POST needs the session token when the call is authenticated and the visitor token - with the SameSite=Strict cookie it is bound to - when it is public. 64 KB body cap; statuses from the shared refusal map (429 for the caps, 409 for a replayed confirm). Switched off, it answers 403 and mints nothing | `lazysite-odoo.pl`; t/integration/170 |
| OT (CU's "report handed to TT") | **`tt_page_var: x: odoo:ID`** renders a READ binding's report into a page, run as `public` with no request input. A render never runs an operation that writes (or one that cannot be asked whether it does); never renders a binding that works on a visitor's key (the render is shared and cached); and escapes every scalar in the report as a `db:` row is (SM786). Logged by name when it refuses | `lazysite-processor/sources.pm` (`resolve_odoo`, `_odoo_inert`); t/unit/odoo/14 |
| OB1 (R1) | **The operator's actions**: `odoo-status` (the connection without its key, `has_secret` three-state, OOM's state, the installed operations), `odoo-secret-set`, `odoo-secret-clear` (POST-only), `odoo-calls` (the record). `manage_connectors`, on every lint the connector's four pass; no MCP twin - setting a credential is an operator act, and the agent's surface is slice E's | `Lazysite::Odoo::action_odoo_*`, `lib/Lazysite/ControlApi/Actions.pm`, `lazysite-manager-api.pl`; t/unit/odoo/15 |

Decisions taken here:

- **The endpoint's mode.** A verified session is `authenticated` where the binding
  admits that mode, and `public` everywhere else - the form handler's precedent
  ("public because anyone could have posted"). A signed-in account reaching a public
  binding as the public gains nothing an anonymous visitor lacks.
- **A page render is `public`, always,** and refuses a write: whatever a page binds is
  read on behalf of whoever loads it, and cached for the next.
- **The ledger moved**: t/lint/98 counts 112 token-reachable actions (was 108), with
  the four named and the reason.

## Slice R - the interface built 2026-10-12 (n474); the wiring STOPPED on a question

| Row | What | Where |
| --- | --- | --- |
| R4, Q3 | **The portable-type interface Q3 asked R to be built against.** Per field it reads `portable_type` (one of the data extension's seven), `values` (enum), `digits`/`places` (decimal), `string` (label), `required` - and NEVER Odoo's own `type`, so it cannot guess. A field without a portable type, with one the data extension does not know, or that fails the data extension's own descriptor check (`Lazysite::Data::Descriptor::load_descriptor`, so an Odoo column is held to a site's rules) is refused BY NAME with the reason. The key name is one constant (`$TYPE_KEY`) for OOM's answer to move | `Lazysite::Odoo::Fields::descriptor_fields`; t/unit/odoo/16 |
| R4 | **The parameter form**: one field per name the binding lets a request set, typed from the operation's declaration (OOM's `str`/`int`/`bool` to `text`/`integer`/`boolean`), required where the operation requires it without a default, carrying the default - and no field for the visitor key or a fixed value | `Lazysite::Odoo::Fields::form_fields`; t/unit/odoo/16 |

### Open: R-Q1 - where a report carries its rows' descriptors (STOPPED HERE)

Neither the rulings nor this filing settle it, and it is an interface between OOM's
operations and lazysite, so per the standing instruction the wiring stopped and the
question is recorded rather than decided.

The interface above turns descriptors into the data extension's fields. What it
needs from a REPORT is the rows and the descriptors that describe them, and an OOM
report is whatever its operation returns: `crm.select`'s, `crm.inspect`'s and a
future pack's each have their own shape. The descriptors come from OOM's
`Profile->descriptors($logical_model)` (section 8), which only the operation can
call - the logical model is the pack's knowledge, and lazysite naming one would break
*The rule that keeps it general-purpose*.

**Recommended:** a read operation meant for display returns `rows` (a list of
hashes) and `fields` (descriptors keyed by the row keys, with `portable_type`, as
`Profile->descriptors` gives them once OOM adds the portable type). Lazysite then:

1. hands TT `x.rows`, `x.fields` (drawn by `descriptor_fields`), `x.refused` and
   `x.form` (`form_fields`) beside the report for an `odoo:` page binding;
2. answers the same keys from the endpoint, so the data helper
   (`starter/assets/lazysite-data.js`) can fill a region from a binding as it fills
   one from a table (`data-ls-odoo="ID"` beside `data-ls-db`);
3. leaves a report without `fields` exactly as CU hands it over (unformatted), so
   nothing that works today changes.

The test pack's `shop.products` already returns that shape. The question is filed to
OOM with the options paper (its second section), since OOM decides what its
operations return. Answering it unblocks the wiring (about half of R's S-M), and
then E.

**ANSWERED 2026-10-13 by OOM: agreed as recommended**, in 0.02. A display read returns
`rows` (a list of hashes keyed by logical field) beside `fields` (the descriptors keyed the
same way, carrying `portable_type`), built with `Operation->fields_for($model, @fields)`;
`crm.export` does so with `inline=1`, and other reads adopt it as they are touched. A report
without `fields` is handed over as today. The key is `portable_type` (the first question,
answered as option A with the per-field override of B). The wiring described above is now
unblocked; it is not built in this re-filing. See section 8 of the filed specification and
`/srv/projects/odoo/oom/inbox/archive/2026-10-13-answered/2026-10-12-field-type-mapping-options-for-lazysite.md`.
## Slice R, the wiring - built 2026-10-13 (n581)

OOM answered R-Q1 as recommended (0.02; see the answer under *Open: R-Q1*), and the release
manager said on 2026-10-13 that the updated deb "can now start to be integrated".

| Row | What | Where |
| --- | --- | --- |
| R4, R-Q1 | **A display read's descriptors, drawn or refused by name.** `odoo_run`/`odoo-run` (and the page endpoint, which answers the same result) hand back `fields` (drawn by `descriptor_fields`, so each is held to the data extension's own descriptor check) and `refused` (`{ field, why }`) **beside** `report`, which stays as the operation returned it. The `odoo:` page binding hands TT the report with `fields` drawn, `refused` named and `rows` cut to the drawn columns: a value of a field lazysite refused to draw is never put on a page. A report whose `fields` is not a mapping of descriptors (none, or the list of names from before 0.02) reaches every door exactly as it did. A field title from Odoo is escaped like any other value | `Lazysite::Odoo::Fields::present`, `page_report`; `_run` in `lib/Lazysite/Odoo.pm`; `resolve_odoo`; t/unit/odoo/23 |

Not built: `x.form` (the parameter form, `form_fields`) on the page binding, and a
`data-ls-odoo` region in the browser data helper; the second is slice D's browser module.

## Slice B - built 2026-10-13 (n582), session-only

The release manager, 2026-10-13: "oom deb is now updated. still more to do, however it can
now start to be integrated." The coordinator took that as the go for the B-Q1 recommendation
(build B session-only first, then C and D). **Not built, and not ruled: an API-key strategy**
(an API key cannot start a session on Odoo 16 or 19). Not built: F2, the per-user path's
SECURITY.md and docs entries.

| Row | What | Where |
| --- | --- | --- |
| OA2, B | **A person signs in to Odoo through a page.** `POST {signin, login, password, visitor_token}` to the Odoo endpoint hands the password to OOM's session transport (`Odoo::Transport::Session`, OOM 0.03), once; the answer sets the session cookie and carries a name for a greeting. `POST {signout, visitor_token}` ends the session at Odoo and clears the cookie. A sign-in needs the visitor token (bound to the visitor cookie, `SameSite=Strict`), so a cross-site form cannot sign a victim in as someone else | `Lazysite::Odoo::sign_in`, `sign_out`; `lazysite-odoo.pl` (`_signin`, `_signout`); t/unit/odoo/25, 27 |
| OA4 | **The credential cookie** `lzs_odoo_session`: the session id, the time it was minted and a signature (HMAC, domain-separated, under the extension's own secret), so a value this server did not mint names nothing and the cookie ends in 12 hours whatever Odoo says; `HttpOnly`, `SameSite=Strict`, `Secure` over HTTPS, `Path` the endpoint's own (nothing else on the site receives it). The id is never in a URL, a body, a log or a record: a record names `session:<hash>` | `Lazysite::Odoo::Session`; t/unit/odoo/24, 27 |
| B | **A binding says whose credential runs it**: `credential: connection` (the default) or `session`. A session binding is authenticated mode only (no public, no schedule: there is no person), takes no callers (Odoo decides, for the person) and no visitor key, and **needs no connection-user key**. It runs through OOM's session context carrying the person's session as the cookie on every call | `Lazysite::Odoo::Binding::parse`, `context`, `session_binding`; t/unit/odoo/26 |
| B | **No fallback, ever.** Without a sign-in a session binding is refused (`signin-required`, 401) and the connection user is not asked; when Odoo has ended the session (or no longer accepts it) it is the same refusal, the cookie is cleared, and nothing is run in its place. The override capability is not a sign-in | `gate`, `_session_end`; t/unit/odoo/26, 27 |
| B | **No other door runs one**: the control API and MCP refuse it and do not list it; a form and the schedule refuse it by name; the `odoo:` page binding renders nothing for it (a page render is shared and cached, and what one person may see is never put in it). A session handed to a connection binding is ignored: what runs as the connection user is never recorded or owned as a person | `action_odoo_bindings`, `Handlers::_to_odoo`, `resolve_odoo`; t/unit/odoo/26 |
| B | **A plan made by a session is that session's**: owned by the hash of the session, applied only by it, approved by it (OOM's run registry), through the person's own session. A binding changed between the plan and the confirm does not change whose plan it is | `confirm`; t/unit/odoo/26 |
| B | **Two-factor accounts are refused by name** (`two-factor`, 403): Odoo accepts the password and opens no session. OOM names this case only in its message, which is read for it and nowhere else; a distinct fault is asked of OOM (below). A wrong password and an unknown login are told alike (`signin-refused`, 401) | `Lazysite::Odoo::Session::_classify`; t/unit/odoo/25 |
| B | **Sign-in attempts share the site's limiter**: `Auth::LoginRate`, counted before Odoo is asked, per address and per login (`odoo-ip=`, `odoo-login=` keys; the login by hash), five in five minutes; the sixth is `rate`, 429 | `Lazysite::Odoo::sign_in`; t/unit/odoo/27 |
| B | **The declared minimum is OOM 0.03** (the first with the session transport), in `owns.deps`, the gate's refusal, the tests and the docs | `plugins/odoo.pl`, `$OOM_MIN` |

**The password**, tested with a stand-in for HTTP under OOM's real transport that records every
post: it is in exactly one post (the authenticate route), in no URL or cookie, and in no result,
log, call record or audit line - including when a transport failure echoes the request body into
its own message. No text of an error from a sign-in is returned or logged, only its kind.

**Asked of OOM** (in the groups-read filing, n583): a distinct fault, or a field on the error,
for "the login was accepted and no session was opened", so that a two-factor account is not
recognised by reading OOM's message.

## Slice C - built 2026-10-13 (n583)

The identity half of the per-user path (OI1 to OI5, OT1, OT2), on the same release manager
go as slice B. **Identity is for presentation only, never authorisation (OI4):** nothing in
the engine reads it to permit anything; a call is run, or refused, on the person's session,
which Odoo checks.

| Row | What | Where |
| --- | --- | --- |
| OI1, OI2 | **The identity cookie** `lzs_odoo_identity`, a second cookie beside the credential: a name, language, time zone, the companies and the groups - never the session id, a user id, a login, an admin flag or a password. Signed under the extension's secret with a label of its own (a session cookie's signature cannot be replayed as an identity), so **a tampered identity is no identity** and the page renders as though nobody had signed in. `HttpOnly`, `SameSite=Lax` (a link from another site still greets the person; it carries nothing that can act), `Secure` over HTTPS | `Lazysite::Odoo::Identity`; t/unit/odoo/28 |
| OI3 | **Short, and refreshed on the next call after it ends.** `odoo_identity_ttl` (60 to 86400 seconds, default 900), dated inside the signature and as the cookie's `Max-Age`. A person with a session and no current identity cookie is asked of Odoo once, through their own session (one round trip), on the endpoint's next call; Odoo having ended the session clears both cookies and the call is told to sign in | `Lazysite::Odoo::identity_ttl`, `refresh_identity`, `Session::identity_of`; `_refresh_identity` in `lazysite-odoo.pl`; t/unit/odoo/29 |
| OT1, OT2 | **The TT namespace**: `tt_page_var:` with `me: odoo-identity:` gives `me.name`, `me.lang`, `me.tz`, `me.company_id`, `me.company_ids`, `me.groups`; every value HTML-escaped as a `db:` value is. A viewer with no cookie, an ended one or one that does not verify gets an empty mapping | `resolve_odoo_identity`; t/unit/odoo/30 |
| OI5 | **The cache, fail-closed, by SM857's own mechanism**: a page whose front matter holds an `odoo-identity:` binding is per-viewer (`$per_viewer`), so it is never read from or written to the page cache and is no-store on output; a binding the front-matter peek did not see (a variable outside the page's own front matter) is REFUSED rather than rendered, because what it read could be cached for everyone | `_peek_md` (`odoo_me`), `main`, `resolve_odoo_identity`; t/unit/odoo/30 |

**Groups: empty until OOM provides them.** OOM's session identity carries no groups, and the
read of them (`res.users`, under `groups_id` to 16 and `group_ids` on 19) is Odoo knowledge
that t/lint/240 keeps out of lazysite. `me.groups` is an empty list, filled from OOM when it
offers a read. Asked of OOM, with a distinct fault for a login that opened no session:
`/srv/projects/odoo/oom/inbox/2026-10-13-lazysite-asks-for-a-groups-read-and-a-no-session-fault.md`.

## Slice D - built 2026-10-13 (n584)

The browser half of the per-user path (OA6), and the last slice of the stack the release
manager's go covered. **Not built: F2.**

| Row | What | Where |
| --- | --- | --- |
| OA6 | **One browser module for the Odoo endpoint**, `/assets/lazysite-odoo.js`, so no page writes its own fetch: it fetches the tokens (`?csrf=1`) and sends the right one on every POST; on a stale token fetches fresh ones and **retries once, never twice**; on `signin-required` asks the person to sign in and **retries the call once** (so a wrong password cannot loop), or not at all when the caller says `prompt: false`; signs in and out; fills regions as text. `read`, `write`, `confirm`, `signIn`, `signOut`, `prompt`, `load`, `fill` on `window.LazysiteOdoo` | `starter/assets/lazysite-odoo.js`; t/unit/odoo/31 (under node, with a fake fetch that records every request) |
| OA6, outcome 10 | **The re-authentication prompt**: a dialog (`role=dialog`, `aria-modal`) with a login box and a password box (`type=password`, `autocomplete=current-password`, so a password manager fills it). The password is read, **the box is cleared before the answer arrives**, and it is in the body of one POST to the page's own endpoint and nowhere else: not a URL, a header, a later request, a cookie, storage, the console or an event. The session id is in an HttpOnly cookie this script cannot read; the script never holds it | `API.prompt`; t/unit/odoo/31 |
| OA6 | **Regions**: `data-ls-odoo="BINDING"` (request fields as `data-ls-odoo-<name>`) with a `<template>` row, as `data-ls-db` is; filled from the report's rows, **only for the fields the server drew** (`fields`; a field it refused is never filled) and **always as text** (`textContent`; nothing here builds markup from what Odoo returned). `data-ls-odoo-signin`, `data-ls-odoo-signout` and `data-ls-odoo-name` are the controls. A region that needs a sign-in keeps what it had and says `data-ls-odoo-state="signin-required"` unless it carries `data-ls-odoo-prompt` | `API.load`, `fill`; t/unit/odoo/31 |
| SM382, DP-3b | **Shipped as the data helper is**: injected only on a page whose rendered markup carries a region or control it binds, on both render paths, once, with a version query; on the exact engine-asset list so it resolves on a domain with its own content root | `lazysite-processor/layout.pm` (`_inject_odoo_helper`), `pipeline.pm` (`_is_engine_asset`); t/integration/174 |

The module holds no storage (`localStorage`, `sessionStorage`, `indexedDB`, `document.cookie`),
no `innerHTML`, no `eval` and no `console`: held against its source by t/unit/odoo/31.

## Slice E - built 2026-10-12 (n475)

| Row | What | Where |
| --- | --- | --- |
| R5, OM2 | **Every Odoo action has its MCP twin**, declared once on the action (SM943): `odoo_status`, `odoo_calls`, `odoo_secret_set`, `odoo_secret_clear` (`manage_connectors`, as on the control API; the key is never returned), and three new action pairs for running a bound operation - `odoo-bindings`/`odoo_bindings` (what this caller may run, with each one's fields), `odoo-run`/`odoo_run`, `odoo-confirm`/`odoo_confirm` | `lib/Lazysite/ControlApi/Actions.pm`, `lazysite-mcp.pl`, `lazysite-manager-api.pl`; t/unit/odoo/17, t/integration/171 |
| OB4, OM2 | **An operation reaches an agent through a binding**, as it reaches a page: gate `ALWAYS` on the action (as connector-call's), and the binding's modes, callers and caps decide inside `Lazysite::Odoo::call`; only mapped fields, checked as on every door. An agent is AUTHENTICATED and never a visitor: a binding that works on a visitor's key is neither listed nor run on this door | `action_odoo_bindings`, `action_odoo_run`, `action_odoo_confirm`; t/unit/odoo/17 |
| Q2, OM1 | **A grant runs as its own Odoo account when one is configured, else as the connection user.** `odoo-secret-set` with `grant` (the lazysite account) and `login` stores that account's key as the connection user's is (0600, its own file, named by a hash of the account); `odoo-status` lists each grant with `has_secret` three-state; a grant map that cannot be read refuses rather than falling back to the (likely wider) connection user; a configured grant without its key is refused, not run as the connection user. The control API's door stays the connection user's | `account_for_grant`, `_as_account`; t/unit/odoo/18, t/integration/171 |
| Forgery, instance-wide | The four key and status actions and their twins sit in t/unit/manager/226 and t/integration/114; `odoo-run` and `odoo-confirm` are recorded in t/lint/218 as not instance-wide (the binding decides, and running one changes no setting) | |

Not built in E, and why:

- **`manage_odoo` (OM3).** The Odoo actions stay under `manage_connectors`, the
  capability that already governs where site data goes and with what credential;
  a capability of its own costs the map, the grid, both gates and the docs and is
  a decision to take on its own.
- **One tool per registry operation, unbound.** Every operation reaches an agent
  through a binding instead, so the binding's callers, modes, caps and parameter
  rules (no json, list or path from a request) hold on this door too. An
  operation an operator wants an agent to run is bound for it.

### E-Q1 - what a binding's `domain:` limits (found 2026-10-12 on SM1051's rebase) - RULED AND BUILT

**E-Q1: as recommended, approved 2026-10-13.** The release manager's words,
relayed by the coordinator: "a binding with a `domain:` runs only for requests
on that domain (the page endpoint, the `odoo:` page binding, and
odoo-run/odoo_run, with the caller's own domain for MCP and the control API);
a binding without one stays instance-wide."

Built (branch n576) in the one function that sends, `Lazysite::Odoo::call`,
so every door meets it: a request on a host (the page endpoint, the `odoo:`
page binding, a form bound to the binding) runs a domain's binding only when
its host is that domain; the control API and MCP, which have no host, run it
only for a caller that reaches the domain by SM976's one rule (an unconfined
operator does, a grant confined elsewhere does not, a grant naming no scope
reaches none); the schedule names neither and runs what the operator
scheduled; a call that names neither outside the schedule is refused, never
assumed. The refusal is kind `wrong-domain` (403), recorded in the call record,
and `odoo-bindings`/`odoo_bindings` list only what the caller may run.
t/unit/odoo/19-20, t/integration/172.

The finding as filed:

SM1051 gave every handler an optional `domain:`, and an `odoo` binding is a handler,
so it takes one. What the domain governs today is what SM1051 built for every
handler type: who may create, change and delete the binding (that domain's editors)
and which forms may bind it. It does **not** limit where the binding RUNS: the page
endpoint (`lazysite-odoo.pl`), an `odoo:` page binding, `odoo-run` and `odoo_run`
find a binding by id on any domain the instance serves. A binding an operator
meant for one site's shop can therefore be run from another site's pages or by an
agent confined to another domain, within the binding's own modes, callers and caps.

Neither the rulings nor this filing settle whether it should. **Recommended:** a
binding with `domain:` runs only for a request on that domain (the page endpoint
and page binding by the request's host, a confined caller by its reach); a binding
without one stays instance-wide, as it is for every other handler type.

Once OOM answers R-Q1 (where a report carries its rows' descriptors), `odoo_run`
and `odoo-run` hand back `fields` (drawn by `descriptor_fields`) and `refused` beside
`report`, as the page binding will.

## F1 - built 2026-10-13 (n577)

| Row | What | Where |
| --- | --- | --- |
| F1 | **SECURITY.md**: four operator entries - the connection user's key, the visitor key, the anonymous write path and its caps, a grant's own Odoo account | `SECURITY.md` |
| F1 | **FEATURES.md**: the extension's section (beside plugins and handlers) and one line in *The security model in one place* | `docs/FEATURES.md` |
| F1 | **The extension's page**, `/docs/odoo`: what it needs, the connection, the key, bindings, where a binding runs, the anonymous write path, a grant's account, domains, the call record, refusals, what is not built; listed in the docs index | `starter/docs/odoo.md`, `starter/docs/index.md` |

# What this is for, and the work - RESTATED 2026-10-01

This replaces a section I wrote earlier the same day. **I had it wrong, and the
correction matters more than the error**: I read a description of future scope as a
programme to build, and wrote SM747 up as a "headless ERP programme". It is not one.

**What the release manager actually said, and what follows from it:**

- The functions named - invoicing, sales, quotes, timesheets, expenses, stock
  movement, manufacturing, visitor registrations - are **future scope, shown to
  convey where this leads. They are not a build.** Whether any of them exists is an
  outcome a lazysite app might or might not implement.
- **The apps are the site agent's work, guided by demand on the day.** Not planned
  here, not sized here, and not this filing's business.
- **What is needed here is a general-purpose Odoo interface, as originally
  described, that apps can be built WITH.** A facility, not an application.

So this filing's scope is unchanged from its original shape. What changed is that the
reason for it is now evidenced rather than asserted.

## Why a facility, from three attempts that each stopped short

| Attempt | What it proved |
| --- | --- |
| **jpm stock correction** - Claude read the lazysite database and transferred to Odoo by hand | The agent WAS the API. It works once and does not scale: every correction needs a person-shaped process, and nothing a visitor does can reach Odoo at all |
| **The agent CRM for opendigital** - Claude talks to Odoo through OOM | Better: one way of speaking to Odoo, with scope and audit. Still agent-driven, so **still no real-time UI** - a person waits for an agent rather than using a page |
| **Pocket portal** - built to bridge exactly that gap | A bridge works and is **heavy to adapt**. One per app is the bespoke-connector sprawl in another form |

The pattern is the same each time: the capability exists, and **the engine offers no
way for an ordinary page to use it**, so every app improvises a bridge. That is the
hole this filing fills - and it is why the measure of success is "an app could be
built on this without inventing a transport", not "Odoo is integrated".

## The rule that keeps it general-purpose

> **Lazysite holds no Odoo knowledge.** Model names, field names, domains,
> `execute_kw`, RPC shapes and the ERP's semantics live in OOM's operation packs.
> Lazysite names an operation, binds its parameters, renders the descriptors it is
> handed, and presents a plan for confirmation.

This is what makes it a facility rather than a connector: an app that needs invoices
needs an operation pack, not engine work. It is **checkable** - a lint refusing any
Odoo model name, `execute_kw` or Odoo RPC endpoint in lazysite code - and the gate
lands with the first code, since there is nothing to check today.

And the rule already in *Scope control* becomes more load-bearing as apps multiply:
a lazysite interface narrows **what is asked for**, never what came back. Odoo's own
ACLs are the bound, under the user's own credential (X4-b). A page that filters is a
page that can be wrong in the direction nobody notices.

# The plan, SIZED 2026-10-02 against the machinery it would reuse

> **Re-planned 2026-10-12 under the ruling** - see *The slices, re-planned
> 2026-10-12* below. The two subsections that follow ("there is no cheap read-first
> slice"; "the real blocker is a ruling") were right against the text as it stood and
> are kept as the reasoning the ruling answered: R1 permits the site-level account,
> and R2 takes the ruling they asked for.

Five stages. **Each one ends somewhere an app could be built**, which is the test of
whether a stage is worth cutting at. Sizes are mine, calibrated on SM929 from
2026-10-01 - one definition adopted at 44 call sites, two lints, three tests and docs
came to 34 files and about 1,540 lines, which is one working session.

## First, a correction: the slices cannot be ordered the way I first wrote them

An earlier version of this section proposed starting with a **site-level Odoo
account**, so that a read-only page could be built before the per-user credential
work. **This filing's own required outcomes forbid it**, and I had not read them
against my own plan:

- **outcome 2**: every operation is attributed in Odoo to *that user*, **not to a
  shared integration account**;
- **outcome 4**: no Odoo credential is stored anywhere on the lazysite server, in any
  file, table, log or cache;
- **OB1**: no shared service account for the user-facing path - a service account is
  permitted only for the MCP surface (OM1), on the mode-600 convention.

So **there is no cheap read-first slice.** The same pass found a second invention of
mine: I described stage 2 as "a page surface rendering an operation's result", but the
TT surface this filing asks for (OT1, OT2) is **identity exposure for presentation**.
"Render an operation's result in a page" is not a requirement row at all.

## And the real blocker is a ruling, not a build

OA2 is the session strategy. OA3's *preferred* form uses the API key **once** to
obtain a session and discards it. Both need `/web/session/authenticate` +
`/web/dataset/call_kw` - **the transport OOM does not have**, whose `Credential`
refuses `session` and `cookie` by name (see the filed specification, section 7).

OA3's stated fallback is to carry the key in the cookie, and OA3 says in its own words
that this "is a materially different risk and must not be silently adopted".

> **Everything per-user waits on one answer: carry the key with the risk documented,
> or wait for OOM to gain the session transport.** That is a ruling, and until it is
> taken, slices B, C and D below cannot start.

**UPDATE 2026-10-13: OOM built it.** `Odoo::Transport::Session` shipped in 0.03 and is live on
Odoo 16 and 19 (section 7 of the filed specification); the blocker below is gone, and the
ruling it asked for is narrower than this section says - see *B-Q1* near the end, which
also records that an API key cannot start a session on either series, so OA3's preferred
form does not exist.

And the transport belongs in **OOM**, not here: endpoint paths and payload shapes are
Odoo knowledge, which *What this is for* puts in the operation packs. The
specification says "for the extension to implement"; that would put Odoo RPC knowledge
in lazysite and contradict the rule. **Resolving that is part of stage 0.**

## What the existing machinery actually gives, measured

| Need | What exists | Cost |
| --- | --- | --- |
| OB4 mode gating | `Lazysite::Egress` (187 lines); `may_invoke` is called from exactly one site, `Connectors::may_call`, and `call()` invokes it **before anything is sent** so all three of its callers are gated whether they remember or not. Its comments already name `proxy` | **nil** - and copy the placement, not just the call |
| OA5 CSRF on the lazysite leg | `Auth::Session::generate_csrf_token` / `verify_csrf_token`, with manager-api's token endpoint and its three accepted carriers | **wiring only** |
| OI5 cache safety | `nocache` is peeked by `_peek_md` and bypasses `try_serve_cache` entirely; `query_params` already skips the cache read when a declared param is present; a `url:`-backed page is marked live in its `.deps` record | **S** - the "fail closed on an identity binding" half is another key in the same peek, not new machinery |
| Outcome 8's two-session proof | `t/lib/ManagerSession.pm` (180 lines): `add_user`, `cookie_for`, `csrf_for`, `call` | **nil** |
| Plan-then-confirm (when writes arrive) | Three precedents, the best being `Data::Tables::import_rows` - validate-and-diff then commit **through one function selected by `apply`**, so "the preview and the action cannot disagree". Also `data-migrate-plan`/`data-migrate`, and `group-reset` where the dry run's diff *is* the confirmation | **nil as design** |
| OB1 config and the store shape | `Manager::Connectors` (979 lines): secrets in a separate 0600 file never returned, `has_secret` as a three-state answer, modes, callers, a per-call JSONL log, age pruning | **copy the pattern** |

**Two rows I first called free and are not:**

- **The HTTP client.** `Lazysite::Fetch` (103 lines) cannot serve Odoo: GET only, no
  headers, no body, no credential, returns the decoded body or nothing - and its SSRF
  guard **refuses private ranges**, which is where an internal Odoo lives. The
  connector already met this and builds its own agent inline in `call()`, deliberately
  not running `is_safe_url` and saying why. So OB6's "the connector's transport
  discipline, reused as behaviour" means **extracting that agent from a 979-line
  module that 53 test files mention** - M to L, not free. Neither client *asserts* TLS
  verification; both inherit LWP's default, which an environment variable can change,
  so the extension should assert it rather than inherit it.
- **The rate cap.** `Egress::within_caps` exists for this shape and **the connector
  does not use it**: it recomputes a rolling hour by scanning `calls.jsonl` on every
  call, and refuses if the log is unreadable. OB5 wants a cap **per identity**, which
  is a different key and a per-request file scan on a page-rate surface. A design
  question, not a copy.

**And the extension point is not where I assumed.** A connector has **no `type`
field**; `format` is `json|slack` in a regex with four touch points. The real registry
is handler types - `@TYPE_ORDER = qw(smtp file table connector)`, each with its own
schema. An Odoo endpoint is naturally **a new handler type**, not a connector format.

## The slices, re-planned 2026-10-12 under the ruling

**The 2026-10-02 table, as history.** It had six slices: A (endpoint config, proxy
skeleton, fault kinds, the audit record, mode gating) buildable but demonstrating
only refusals; B (one per-user credential strategy) blocked on a ruling; C (identity
cookie, TT exposure, cache fail-closed) and D (browser data module, CSRF, re-auth
prompt) after B; E (MCP under the agent's own account) independent of B; F (docs and
the boundary lint) last. The first page capability was A + B + C + D, four M slices.
R1 removes B from the front of that queue: the connection user gives a page Odoo
facts with nobody signed in to Odoo, so the first page capability no longer needs
the per-user legs.

Sizes keep the 2026-10-02 calibration (one working session is about 34 files and
1,540 lines, from SM929). **Building** needs nothing from anybody: the engine works
against the OOM tree on a library path, and OOM's `Odoo::Ops::Context` takes an
injected transport for tests (`Context.pm:49`), so `t/unit/odoo/` needs no Odoo.
**Shipping** waits on the deb carrying the Ops layer (R3, OB7).

| Order | Slice | What it is | Size | Waits on |
| --- | --- | --- | --- | --- |
| 1 | **A** | Endpoint config (`odoo_url`, `odoo_db`, `odoo_timeout`) as a new handler type; OOM's fault kinds and categories mapped to `{ ok: 0, error, kind }` with OB5's distinct kinds, the fault text logged and never returned; the OB8 audit record; mode gating through `Lazysite::Egress`; X4-a's URL rule; **the boundary lint** from *The rule that keeps it general-purpose*, which lands with the first code | **M** | nothing to build |
| 2 | **CU** (new) | **The connection user.** Its secret store (OB1 as amended: 0600, written alone, never returned, `has_secret` three-state, set and clear actions); an OOM context per call with the key and `actor` = the lazysite account that triggered it; operations found through `Odoo::Ops::Registry`; a page binding that names an operation, binds its parameters and declares its SM579 modes; a read operation's report handed to TT; a write operation's plan shown as its buckets and applied on confirm through `Odoo::Ops::Runner`, the confirm carrying the manager-api CSRF token (OA5, brought forward from D); plans and journals in the extension's private store, never the docroot, pruned by age | **L** | nothing to build; Q1 before any unattended apply |
| 3 | **R** (new) | **Shared rendering** (R4): an operation's rows and its parameter form drawn by the data extension's table and form rendering, from OOM's `Profile` descriptors (`Profile.pm:211-221`) | **S-M** | CU; Q3 decides where the type mapping lives |
| 4 | **E** | **MCP, all operations** (R5): one tool per registry operation, generated from its declaration; list and describe; one apply-plan tool; under the connection user (OM1 as amended), the `manage_odoo` capability (OM3), lazysite-side audit | **M** | CU (shares its runner and store); Q2 |
| 5 | **F1** | SECURITY.md (the outbound interface, and the connection user's stored credential as a threat delta), FEATURES.md (OB9), the extension's page including the onchange obligation (spec section 10) | **S** | A, CU, E |
| later | **B** | One per-user credential strategy end to end: acquire, carry, replay, clear, logout, outcome 10's re-authentication prompt | **M** | OOM's session transport (R2) - **shipped 2026-10-13, 0.03**; B-Q1 |
| later | **C** | Identity cookie (OI1-OI3), signed and TTL'd; TT exposure (OT1, OT2); the cache fail-closed (OI5) | **M** | B |
| later | **D** | The shared browser data module (OA6) and the re-authentication prompt in the UI; CSRF has moved to CU | **S-M** | B |
| later | **F2** | The per-user path's SECURITY.md and docs entries | **S** | B, C, D |

**The first demonstrable page capability is A + CU + R**: a page lists Odoo facts
from a named read operation under the connection user, drawn as a data table, and a
page whose operation writes shows the plan's buckets and applies them when a signed-in
lazysite user confirms. M + L + S-M, about three sessions. A + CU alone already
demonstrates it with the report unformatted; R is what makes it an app rather than a
dump. **E follows at about one session** and is the cut that answers R5. B, C and D
were to start when OOM shipped the session transport; it shipped 2026-10-13 (0.03).
Whether to start them is the release manager's, asked as B-Q1; the per-user path is
the original A + B + C + D minus the work CU has already done.

## Two findings from the measurement, neither urgent

- **Two retention numbers for one fact.** `connector_call_retention_days` (default 90)
  prunes the call log on every append, while `$KEEP_CALLS_DAYS = 30` is used only by
  `sweep()`. One of them is wrong about how long a call record lives.
- **OB8's record does not exist in any form yet.** `audit_log` is never called from
  `Manager::Connectors`; the audit trail records at *delivery* level - `act='deliver'`,
  naming the handler rather than the connector or the `call_id`. One record per proxied
  call naming model, method and mode is new work, and `audit_log`'s seven positional
  fields have no obvious room for it.

**What is NOT in the plan:** any of the ERP functions named earlier. They are what apps
do with this, built by the site agent when somebody asks.

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
   proxied call. *(Amended 2026-10-12, R1: holds for every user's credential;
   the connection user's is the one stored credential - see* Ruled 2026-10-12*.)*
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
| OB1 | Per-site Odoo connection in the extension's config: `odoo_url`, `odoo_db`, `odoo_strategies`, `odoo_timeout`, `odoo_identity_ttl`. No shared service account and no stored credential for the user-facing path. If the MCP surface needs a service account (OM1) it follows the mode-600 credentials-file convention and is never displayed. **Amended 2026-10-12 (R1):** the config may hold a connection user, its API key stored as connector secrets are - see *Ruled 2026-10-12*. |
| OB2 | **Scoped mode**: a declared allowlist of models and permitted methods per app. Refused by lazysite before the call leaves. The default for a purpose-built app. (P1's "named queries" live here - a named query is a scoped allowlist with bound parameters.) |
| OB3 | **General mode**: no model or method allowlist; bounded by the user's own Odoo permissions exactly as Odoo's web client is. An allowlist here would mean enumerating Odoo badly and forever. **Applies only to a call made with the user's own credential** - see *Reconciling*. |
| OB4 | Caller gating is lazysite's: the proxy is reached by a lazysite session on an app page (mode 2 of [[SM579]]), and the call carries the Odoo credential from the cookie. No scheduled and no public mode for the per-user proxy. **Amended 2026-10-12 (R1):** the connection-user path takes SM579's three modes, declared per binding. **Ruled 2026-10-12 (Q1):** a public or scheduled binding may apply a write operation unattended when it declares `apply: immediate`, under the controls in *Ruled 2026-10-12 (Q1-Q3)*. |
| OB5 | A per-call timeout (`odoo_timeout`); a rate cap per identity; Odoo faults mapped to lazysite's `{ ok: 0, error, kind }` shape with **distinct kinds** for session-expired, invalid-credential, odoo-access-refused and transport-failure. The fault's own text is logged, never returned verbatim (three leaks in three passes taught this - [[SM713]], [[SM738]], [[SM739]]; `t/lint/112` checks the source). **2026-10-12 (Q1):** the per-identity cap is per visitor key on the public path and per account on the authenticated path, with a per-binding cap beside it. |
| OB6 | Transport discipline, the connector's reused as behaviour: no redirect following - a 3xx is a named refusal, because the credential would travel with it; a response size cap sized for Odoo reads and configurable; TLS peer verification on; `https://` to any host and `http://` only to loopback. **X4-a settled this 2026-09-28: no plain `http://` to an RFC1918 Odoo** - `https://` to a private hostname, which the connector rule already permits, is what "internal network" means here. |
| OB7 | OOM is delivered as a versioned package (`libodoo-oom-perl`); the extension declares a minimum version in `owns.deps` and never carries a copy of the code. Settled by the release manager 2026-09-03. **MEASURED 2026-10-01: THE PACKAGE THAT EXISTS CANNOT SATISFY THIS.** `/srv/projects/packages/libodoo-oom-perl_0.01_all.deb` (2026-09-03, 26,972 bytes) carries **8 modules - the mapper layer only**: Client, Commands, Error, Model, Record, RecordSet and the two transports. The OOM tree has **41**, and the 33 it is missing are the whole `Odoo::Ops::*` layer the specification's layer table says the extension consumes - including `Odoo::Ops::Guard`, **which IS the scoped mode.** Installing 0.01 would therefore give the engine a mapper with no scope guard: general mode only, which X4-b permits solely with the user's own credential, so the named-query mode this filing is built around would be unavailable. `Odoo/Transport.pm` itself is also absent. A **0.02 carrying both layers is a prerequisite of OP-25**, not a later tidy. **Ruled 2026-10-12 (R3):** the deb will be updated; what it must carry is filed to OOM's inbox. **Delivered 2026-10-13:** `/srv/projects/packages/` holds 0.02 to 0.09; 0.02 carries the Ops layer (42 modules) and 0.09 has 63, including `Odoo::Transport::Session`, `Odoo::Transport::JSON2`, `Odoo::Portable`, `Odoo::Ops::Runs`, `Odoo::Ops::Core::User`, `Core::Attach`, `Core::Fetch` and `Core::Doctor`. It is not installed on this host (`dpkg -s libodoo-oom-perl`). **What 0.07 to 0.09 change for the extension (2026-10-13, from the filed specification and OOM's changelog):** (1) **the run registry (`Odoo::Ops::Runs`)**: `Runner->apply` now refuses a plan nobody approved (`unapproved`), one approved as another plan (`approval-stale`) or one past its time (`expired`, `plan_ttl`, default 24 hours), unless the config says `approval = none` - the extension therefore records its own approval, by the plan's maker or by an `apply: immediate` binding, before it applies, and does not turn the gate off (see *OOM's approval gate*); (2) **revert and resume**: a `custom` change may say how it is undone, `revert_plan` and `resume_plan` build new plans, and a run over many rows can continue past a failure - the extension exposes none of these, and a plan it makes is applied once; (3) **`core.user`, `core.attach`, `core.fetch`**: named operations for users (including a portal user made through Odoo's portal wizard, and an API key minted as the user), attachments in and out of any record - they reach a page or an agent only through a binding, as every operation does, and what they may do is the connection user's rights in Odoo; (4) **`Odoo::Transport::JSON2`** for series 19 (`/json/2`, the API key as a Bearer header): selected by OOM's `transport` config key, which the extension does not set, so it uses the default transport; (5) **`oom-ops doctor`**, an OOM operation (config, key file mode, TLS, authentication and groups, write readiness) that is OOM's to run and is not wired here. |
| OB8 | One audit record per proxied call on the lazysite side: actor (lazysite account if any), Odoo login, model, method, mode, outcome state (answered / unanswered / refused / odoo-fault), never the payload and never the credential. Written the way connectors write theirs. **Amended 2026-10-12 (R1):** for a connection-user call the actor is the lazysite account (or mode and binding) that triggered it. **2026-10-12 (Q1):** a public call's actor is `visitor`, recorded with a hash of the visitor key and the IP. |
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
| OM1 | An agent uses ITS OWN Odoo account, configured by the operator - never a human user's credential and never impersonation. Attribution in Odoo's audit trail stays truthful; the agent's Odoo permissions are what bound it. **2026-10-12 (R1):** met by the connection user; Q2 asks whether MCP gets its own. **Ruled 2026-10-12 (Q2):** the connection user by default, or an Odoo account configured for the MCP grant, stored as the connection user's key is. |
| OM2 | Tools follow the connector's naming and error conventions. The exact set is settled when the mapper spec is merged; at minimum: introspect models and fields, read, write, all within the agent's own permissions. **Ruled 2026-10-12 (R5): all operations** - every operation the registry lists is a tool. |
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
   integration account. *(Amended 2026-10-12, R1: on the per-user path. A
   connection-user operation is attributed in Odoo to the connection user and in
   lazysite's audit to the lazysite account or mode that triggered it.)*
3. An operation the user is not permitted to perform is refused by Odoo, and
   the refusal is distinguishable in the response from a transport failure.
4. No Odoo credential is stored anywhere on the lazysite server, in any file,
   table, log or cache. Demonstrated by inspection. *(Amended 2026-10-12, R1: no
   user's credential. The connection user's key is in the extension's 0600 secret
   file and nowhere else, and the inspection proves the second half too.)*
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
  or "for performance". *(2026-10-12, R1: user credentials. The connection user is
  the ruled exception, on OB1's amended terms only.)*
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
| Source | `t/vendor/oom/docs/MAPPER-SPEC.md` |
| Written | 2026-09-28, status DRAFT, "growing with use"; RE-FILED 2026-10-18 from OOM 0.32 (commit bd9610e, "Package 0.32"), the copy lazysite now vendors (SM1167); RE-FILED 2026-10-17 from OOM 0.27 (commit 33136df, SM1156); RE-FILED earlier the same day from OOM 0.24 (commit fc3b3bb, SM1117); before that RE-FILED 2026-10-13 from OOM's working tree as of 6844779 (2026-10-13), after OOM's 0.02 to 0.09; that text is exactly the copy the 0.09 deb installs, and it is the copy lazysite now VENDORS (t/vendor/oom, OOM commit 2edc3db, SM1081) |
| sha256 at filing | `7fd9ef1398f2d2d742da45432967fb6349e668df54977b92e3a2e1aca21a9f0e` |
| Living copy | stays in the OOM tree - that project owns it, and its working tree may be AHEAD of the vendored copy without any failure here |
| Re-file when | a newer OOM is adopted: `tools/vendor-oom.sh` refreshes `t/vendor/oom` and this section is updated from it in the SAME commit (t/lint/207 enforces it, t/lint/261 holds the snapshot to its MANIFEST) |
| Drift gate | `t/lint/207-the-filed-mapper-spec-matches-its-source.t` |

A second copy of a document that is still being edited elsewhere is how two
descriptions of one thing come to disagree, and this filing has already been stale
twice (see *Sequencing*). So the hash is recorded and a lint compares it.

**The gate follows a pinned snapshot, not OOM's working tree (SM1081, 2026-10-14).** The
lint first compared the filing with OOM's working tree, which moved three times on
2026-10-13 and 14 and failed the release gate each time with nothing wrong in lazysite.
It now compares with the copy of the spec inside this repository,
`t/vendor/oom/docs/MAPPER-SPEC.md`, which is always present, so the "source not
readable" skip is gone. OOM's tree may be ahead of it; a newer OOM is adopted by a reviewable commit when the
release manager decides (0.24 was adopted on 2026-10-17, SM1117, and 0.27 the same day, SM1156; 0.32 on 2026-10-18, SM1167). The gate
follows the released spec. B, C and D's blockers, R-Q1 and the rest of this filing are
unchanged by it.

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
`libodoo-oom-perl` package (OB7), never a copy. **That was a requirement on the
package, which the 0.01 deb did not meet (OB7); the debs 0.02 to 0.09 do.**

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

## 7. Credential strategies (OA1) - session shipped, live on 19

`Odoo::Ops::Credential->resolve($config)` returns what the client
needs. `file` (API key file, mode 600 enforced) ships. `session`
ships in 0.03: the config carries a run-time session value (never a
file entry: `Config->load` refuses it), and the context speaks
`Odoo::Transport::Session` as that user. `cookie` stays a reserved
name that refuses: a consumer replaying a per-user credential from a
cookie turns it into a session first.

The session transport: one round trip to `/web/session/authenticate`
(db, login, password) returns the identity and a session id the
caller carries; every later call goes through
`/web/dataset/call_kw/<model>/<method>` with the session cookie,
presented as `call('object','execute_kw', ...)` so the Guard and
everything above it are transport-blind; `/web/session/destroy` on
sign-out; `/web/webclient/version_info` for `common.version`;
`/web/session/get_session_info` once for a resumed session. Expired
or destroyed: category `session` (and the transport forgets the id);
refused login: category `credential`; neither retried. Two-factor
users cannot complete a password session login (Odoo opens no session):
category `second_factor`, `Odoo::Error->is_no_session`. Groups are not
in the identity: `Odoo::Client->session_groups` (and the read operation
`core.whoami`) read `res.users` (in the Guard's base scope) with the
field chosen from `fields_get` (`groups_id` to 18, `group_ids` on 19)
and the names from `res.groups` (`full_name`); a user who may not read
the names gets the empty list with `groups_readable` 0, not a fault.

## 8. Field descriptors - tested (shape and portable type), live on 19

`Profile->descriptor($model, $field)` returns the server's metadata
under the logical name: `type string help required readonly store
relation relation_field selection`, plus `name` (physical), plus a
**portable reading of the type** for consumers that hold no Odoo
knowledge (0.02, `Odoo::Portable`): `portable_type` is one of `text
integer decimal boolean date datetime enum`; an enum carries `values`
(selection keys) and `labels`; a decimal carries `places` (and
`digits`) when the server states them. Odoo types with no single
reading carry no `portable_type`: many2one, html, binary, the x2many
types, reference, json, properties. A profile overrides per field with
the map form `logical: { name: physical, portable_type: text }` (a
many2one shown as its label); an unknown portable type is refused at
load. A profile also names the module it needs: `module:` beside `pack:` (the
pack's own module), on a model, or in a field's map form
(`expiration: { name: expiration_date, module: product_expiry }`). `validate`
lists a missing model or field whose module is not installed in
`not_applicable` and not in `missing`, and the profile reads it as known-absent
(`field` is undef; `fields` and `has_field` leave it out); the installed modules
come from `Odoo::Ops::Modules`, read once per context and only when something is
missing. A consumer that meets a field without `portable_type` refuses to
render it by name - the mapping never lives on the consumer's side.

**Display reads** return `rows` (a list of hashes keyed by logical
field) beside `fields` (those descriptors keyed the same way), built
with `Operation->fields_for($logical_model, @fields)`. `crm.export`
does so with `inline=1`; its report keys are `count`, `file`,
`fields`, `rows`.

## 9. Series - tested (mechanism), live pending

Logical->physical profiles per pack and series, validated against live
`fields_get`; nearest-lower fallback with a warning. Behaviour beyond
names (e.g. sending mail) dispatches per series and refuses on an
unprobed one.

| Behaviour | 16 | 17 | 18 | 19 | 20 |
|---|---|---|---|---|---|
| crm profile | live 2026-09-28 (16.0-20250909): 42/42 fields, restricted CRM user; live 2026-10-13 (local cluster): 43/43 | not probed | live 2026-10-13: the 16 profile validates 43/43 (loader warns it is the 16 file) | live 2026-10-13: the 16 profile misses `crm.lead.mobile` (removed); `profiles/crm/19.yaml` maps it to `~` and validates 42/42 | - |
| `crm.inspect` and `crm.export` (counts by type/stage/tag/source/team/salesperson; rows + descriptors with portable types, no faults) | live 2026-10-13: 9 leads, 31 fields | not probed | live 2026-10-13: 6 leads, 31 fields | live 2026-10-13: 12 leads, 30 fields (no `mobile`); same run over json2: inspect ok | - |
| crm profile | live 2026-09-28 (16.0-20250909): 42/42 fields, restricted CRM user; live 2026-10-13 on the local 16: 9 models, 50 fields with `res.partner` mapped (`core.check`) | 16 file validates live (TEST-RESULTS, series 17 and 18) | live 2026-10-13: `profiles/crm/18.yaml`, 9 models, 50 fields | live 2026-10-13: `profiles/crm/19.yaml`, 9 models, 49 fields; `crm.lead.mobile` is absent on 19 (the 16 file named it) | - |
| `/jsonrpc` + `execute_kw`, API-key auth | live (jpm clone; local cluster 16.0 2026-10-13) | - | - | live 2026-10-13 (19.0, odoo-cluster) | - |
| `copy` answers a list of ids (multi-record since 18) | single id | - | - | live 2026-10-13: `Model->copy` returns one id for one id on every series | - |
| html field written as plain text reads back wrapped in `<p>` | verbatim | - | - | live 2026-10-13 | - |
| `res.partner.date` | present | - | - | absent, live 2026-10-13 | - |
| read/write/unlink/x2m commands/verify_credentials (t/98, t/99) | live (jpm clone; local cluster 16.0 2026-10-13) | - | - | live 2026-10-13 | - |
| a pallet moved into `WH/Output` by a validated internal transfer reads fully reserved | not seen: the relocate-and-return test ran clean (t/94, 2026-10-13) | not probed | not probed | observed 2026-10-13 (t/94): `reserved_quantity` 8 of 8 after the transfer; cause not isolated | - |
| the opposite transfer of a transfer that left a package split is refused (a package in two places) | refusal reproduced offline only (t/33, the stock fixture); the live mirror undo was not run in this piece; the relocate undo applied live 2026-10-13 (t/94) | not probed | not probed | the relocate undo applied live 2026-10-13 (t/94); the mirror undo not run live | - |
| session transport: authenticate, call_kw, identity, destroy, expiry (t/97) | live 2026-10-13: 17/17 | - | - | live 2026-10-13: 17/17 | - |
| sale: basket as draft order, lines by x2m commands, action_confirm, invoice via `sale.advance.payment.inv` + `create_invoices`, `action_post`, payment via `account.payment.register` + `action_create_payments` (t/95) | live 2026-10-13: paid | - | - | live 2026-10-13: paid | - |
| chart of accounts on a fresh db | `l10n_generic_coa` is a module: `ir.module.module.button_immediate_install` over RPC loads the chart for a company without one; `res.company.chart_template_id` says so (live 2026-10-13) | - | - | `account.chart.template.try_loading('generic_coa', company=)`; `res.company.chart_template` (live 2026-10-13) | - |
| crm.lead create + ir.attachment (image) + message_post note (t/95) | live 2026-10-13 | - | - | live 2026-10-13 | - |
| hr.expense submit | report: `hr.expense.sheet` create + `action_submit_sheet`, state `submit` (live 2026-10-13) | - | - | no sheet: `hr.expense.action_submit`, result in `approval_state` (auto-approved when the submitter is the approver), live 2026-10-13 | - |
| portal user writes their own res.partner over RPC | REFUSED (access) live 2026-10-13, same pattern | - | - | REFUSED (access) live 2026-10-13: the app verifies the session identity (`partner_id`) and applies through its service connection, as Odoo's portal controller does | - |
| portal user reads crm.lead | refused (access), live | - | - | refused (access), live | - |
| API key at `common.authenticate` (RPC) | live 2026-10-13: ACCEPTED (key minted as the user; an earlier probe minted as the superuser was refused and misreported) | - | - | live 2026-10-13: ACCEPTED (same correction) | - |
| API key accepted at `/web/session/authenticate` | live 2026-10-13: REFUSED (credential) - a web session needs the password; "key once, then session" does not exist | - | - | live 2026-10-13: REFUSED (credential) | - |
| module enable over RPC (`button_immediate_install`), `ir.config_parameter.set_param`, `res.config.settings` create + `execute` | live 2026-10-13 (l10n_generic_coa) | - | - | live 2026-10-13 (survey; group_multi_currency; a parameter) | - |
| core.import: keyed create/update of res.partner (country by code, tag created when missing), product.template by default_code, product.product barcode by default_code; re-run all unchanged (t/96) | live 2026-10-13: 31/31 | - | - | live 2026-10-13: 31/31 | - |
| stock profile: quant, location, package, lot, picking, picking type, move, move line, sale line, order, wizards | live 2026-10-13: 12 models, 88 fields; move line `reserved_uom_qty`/`qty_done`, `stock.immediate.transfer` | profile 17.yaml: one `quantity` + `picked`, no immediate wizard (pending live) | - | live 2026-10-13: 11 models, 85 fields; `stock.quant.package` renamed `stock.package`; `stock.move.name` absent | - |
| a transfer that leaves a package in two locations | REFUSED at validation (SA8), live 2026-10-13 (the mirror netting's reversal) | - | - | ACCEPTED, live 2026-10-13 (same reversal) | - |
| `stock.quant.create` with `quantity` (no inventory mode) and `write` of `package_id`/`quantity` by an administrator | ACCEPTED, live 2026-10-13 (how the test seeds anomalies; SB3 on the live site) | - | - | ACCEPTED, live 2026-10-13 | - |
| internal picking type of a one-step warehouse | archived (`active` false); a picking of it validates, live 2026-10-13 | - | - | same | - |
| `product.category.property_valuation` values | `manual_periodic`, live 2026-10-13 | - | - | `periodic`, live 2026-10-13 | - |
| context `lang` naming a language that is not installed | ACCEPTED silently (served in the user's language), live 2026-10-13 (`fr_FR`, `xx_XX`) | not probed (the instance shares the host's one spare alias with 18) | REFUSED on every call: "Invalid language code", live 2026-10-13 - the live harness now sends a lang only when the config names one | REFUSED on every call, live 2026-10-13 (`en_GB` installed there is accepted) | - |
| API key duration for a non-administrator (`core.user` api-key `duration`) | no expiry, live 2026-10-13 | not probed | not probed | default one day; `duration` accepted up to 90 ("You cannot exceed 90.0 days" above that), live 2026-10-13 | - |
| root product category name | `All` (live 2026-10-13) | - | - | `Goods` (live 2026-10-13) - resolve categories by name only with that in mind | - |
| serving slot after an external module install | needs a restart to see new models (live 2026-10-13); the cluster's module-install does it | - | - | same | - |
| `auth_ldap` server model | `res.company.ldap`, not `ldap.server`: `company`, `ldap_server`, `ldap_server_port`, `ldap_base`, `ldap_filter`, `ldap_binddn`, `ldap_password`, `ldap_tls`, `create_user`, `user` (the template), `sequence`; no name field. Live 2026-10-13 (t/24, 39/39); the admin reads `ldap_password` back over RPC | not probed (the instance shares the host's one spare alias with 18) | same fields, live 2026-10-13 (t/24, 39/39, after `module-install demo18.localhost auth_ldap`) | same fields, live 2026-10-13 (t/24, 39/39) | - |
| `ir.module.module.update_list` over RPC as the administrator | ACCEPTED, live 2026-10-13 (t/24: a missing addon name triggers it, then is held `unknown-module`) | not probed | ACCEPTED, live 2026-10-13 | ACCEPTED, live 2026-10-13 | - |
| `ir.config_parameter.unlink` over RPC as the administrator | ACCEPTED, live 2026-10-13 (t/24) | not probed | ACCEPTED, live 2026-10-13 | ACCEPTED, live 2026-10-13 | - |
| `fields_get` of `res.partner` for the mapping skeleton | live 2026-10-13 (t/24): relations, selections and magic columns as the skeleton expects | not probed | live 2026-10-13 | live 2026-10-13 | - |
| two-step delivery (`delivery_steps` = `pick_ship`): what confirming a sale order makes | a pick and a delivery, live 2026-10-13 (t/93) | not probed | the pick only; the delivery is made when the pick is validated, by the route's push rule `Output -> Customers`, live 2026-10-13 (t/93) | the pick only, as 18; `stock.rule` action `push` listed, live 2026-10-13 (t/93) | - |
| writing `delivery_steps` back to `ship_only` | not probed | not probed | REFUSED while the output location holds stock ("You can't disable locations WH/Output because they still contain products"), live 2026-10-13 | not probed | - |
| a pick's reserved move lines: who makes and writes them | created by user 1, written by the confirming user in the same second, live 2026-10-13 (t/93, first run) | not probed | not probed | not probed | - |
| domain term `product_id != 0` on `stock.move.line` | matches no record (0 rows where lines existed), live 2026-10-13; name the product | not probed | not probed | not probed | - |
| lot of a product with `use_expiration_date` and `expiration_time` 0 | `expiration_date` = `create_date`, live 2026-10-13 | not probed | same, live 2026-10-13 | same, live 2026-10-13 | - |
| `expiry.picking.confirmation` on validating a pick that draws such a lot | opened once the clock passed the creation time (SC4), live 2026-10-13 | not probed | not probed | asked for a lot with `expiration_date` 2030 and `removal_date` at creation, after the backorder wizard; none once all four lot dates were 2030, live 2026-10-13 | - |
| reservation of a lot whose lot dates are past, orders made seconds after the lots | not observed (reserved) | not probed | not probed | the second and third orders' picks stayed `confirmed`, nothing reserved; with the dates in 2030, `assigned` with the reservation, live 2026-10-13 (observed together, not isolated) | - |
| `process_cancel_backorder` on a pick or delivery validated below demand | closes it, no backorder picking left, live 2026-10-13 | not probed | same, live 2026-10-13 | same, live 2026-10-13 | - |
| adding a line (`picking_id`, `qty_done`/`quantity`, no `move_id`) to a done pick (SA3) | a done move with no `sale_line_id`, no `move_dest_ids`; `qty_delivered` unmoved, live 2026-10-13 | not probed | same, live 2026-10-13 | same, live 2026-10-13 | - |
| the same on the done delivery, then `write` of `sale_line_id` and `move_orig_ids` `(4, stranded)` | `qty_delivered` rises by the quantity (SC1); the stranded move gains its `move_dest_ids`, live 2026-10-13 | not probed | same, live 2026-10-13 | same, live 2026-10-13 | - |
| `date_done` on a validated picking, `date` on its moves and lines (SC6) | writable, live 2026-10-13 | not probed | same, live 2026-10-13 | same, live 2026-10-13 | - |
| `message_post` on `stock.picking` with `author_id`, `email_from`, `subtype_xmlid` `mail.mt_note` (SD1) | posts as a Note, live 2026-10-13 | not probed | same, live 2026-10-13 | same, live 2026-10-13 | - |
| an order with a draft invoice (a fixed-amount down payment) | `invoice_ids` readable by an accounting user; held `invoiced`, live 2026-10-13; the access error for a user without accounting rights not reproduced | not probed | same, live 2026-10-13 | same, live 2026-10-13 | - |
| read_group row count key `<field>_count` | live (crm.inspect) | - | - | - | - |
| read_group row count key (V14) | `<field>_count` for a lazy grouping, `__count` for `lazy=false`; live 2026-10-13 (crm.lead by type, tag_ids, stage_id) | not probed | same as 16, live 2026-10-13 | same as 16, live 2026-10-13 - not a series difference; `crm.inspect` reads either key | - |
| API key minted over the web session (make_key -> identitycheck -> run_check), then password spent | live 2026-09-28 | - | - | - | - |
| send via composer (mass_mail on one lead, V15) | live 2026-10-13 (t/91 16/16): composer driven by context `active_ids`, field `auto_delete_message` off; copy in the lead's history is `message_type` `email`; mail.mail in state `exception` with no outgoing server (sent at once) | source (17.0 composer: as 18); sender implemented, plan says so | live 2026-10-13 (t/91 16/16): `res_ids` text, `force_send` off; copy is `email_outgoing`; mail.mail `outgoing`, queued | live 2026-10-13 (t/91 16/16, also over json2): as 18 | - |
| composer fields `mail.compose.message` | `res_id`, `auto_delete_message` present; `res_ids`, `auto_delete_keep_log`, `force_send`, `use_exclusion_list` absent (live 2026-10-13) | `res_ids`, `auto_delete_keep_log`, `force_send` in the source; no `auto_delete_message` | `res_id` and `auto_delete_message` absent (a create naming `auto_delete_message` is refused: "Invalid field"); `res_ids` (text, a list), `auto_delete`, `auto_delete_keep_log`, `force_send`, `use_exclusion_list`, `partner_ids` present (live 2026-10-13) | as 18, and `composition_comment_option`, `notify_*` fields added (live 2026-10-13) | - |
| `/json/2/<model>/<method>` (V5) | absent: 404 HTML page (live 2026-10-13) | not probed | absent: the unauthenticated request is redirected (303) to the login page; no `json/2` in the 18.0 source (live 2026-10-13) | present (module `rpc`, `rpc/controllers/json2.py`), live 2026-10-13 | - |
| `/json/2` authentication | n/a | not probed | not probed (no API key minted on 18 for this) | `Authorization: Bearer <API key>` only (route `auth='bearer'`): no header 401 "User not authenticated, use an API Key with a Bearer Authorization header."; the password as bearer 401 "Invalid apikey"; the web session cookie 401 "Missing Authorization or Sec-headers"; live 2026-10-13 | - |
| `/json/2` database selection | n/a | not probed | not probed | header `X-Odoo-Database: <db>`; optional with one database (live 2026-10-13, the instance has one); the 19.0 `test_webjson2` suite: more than one database and no header, or a wrong one, answers a 404 HTML page | - |
| `/json/2` error shape | n/a | not probed | not probed | HTTP status plus JSON `{name, message, arguments, context, debug}` (`debug` is a traceback, never copied by the transport). Missing record 404 `odoo.exceptions.MissingError`; unknown model 404 `werkzeug.exceptions.NotFound`; unknown method 404 (the message names `model.method`); `UserError` 422; bad field in a create or domain 500 `builtins.ValueError`; bad argument name 500 `builtins.TypeError`; missing argument 422 `UnprocessableEntity`; ids given to a model method 422; live 2026-10-13 | - |
| `/json/2` calling convention | n/a | not probed | not probed | the body is the method's keyword arguments by name, plus `ids` (record methods) and `context`; no positional arguments (`default_get` takes `fields`, `write` takes `ids` and `vals`, `create` takes `vals_list`); `create` answers a list of ids, `copy` a list, `write` true; `common.version` is not served here: `/web/webclient/version_info` answers unauthenticated; the key owner's uid comes from `res.users/context_get`; live 2026-10-13 (t/93 18/18, t/95 7/7, t/98 and t/99 45/45 over `transport = json2`) | - |
| `properties` fields (V3): `crm.lead.lead_properties` (definition on `crm.team.lead_properties_definition`, type `properties_definition`) | present, live 2026-10-13: `fields_get` type `properties`, stored; a read answers a list of definition hashes each with its `value`; create and write take a list of `{name, value}`; the default read, `search_read`, `find` and a Record read it without a fault; `Portable::describe` gives no type; filtering by `lead_properties.<name>` faults ("'Properties' object has no attribute 'auto_join'"); writing a dict `{name: value}` replaces the whole set, unlisted values reading `0` (t/92 11/11) | not probed | as 16, except that a domain on `lead_properties.<name>` works (t/92 11/11) | as 18, except that after a dict write the unlisted values are absent from the read (t/92 11/11) | - |
| `project.task` (the other properties model named in V3) | not installed | not probed | not installed | not installed | - |
| send via composer (mass_mail on one lead) | source | - | - | - | - |
| composer field for keeping a copy in the record's history | `auto_delete_message` (source 16.0 mail.compose.message) | `auto_delete` + `auto_delete_keep_log` (source origin/17.0) | same as 17 (source 18.0) | same as 17 (source 19.0) | - |
| a sender with no email address and `message_post` (a lead note) or a lead created for another salesperson | REFUSED "Unable to send message, please configure the sender's email address", live 2026-10-13 (`tmp/probe-noemail.pl`); the same create under `mail_auto_subscribe_no_notify` ACCEPTED | refused (source origin/17.0 `_message_compute_author` raises); not probed, 17 unreachable | REFUSED, live 2026-10-13, as 16 | ACCEPTED both, live 2026-10-13 (source 19.0: `_message_compute_author` has no `raise_on_email`) | - |
| `button_validate` subscribes the validating user | yes (source 16.0) | yes (source origin/17.0) | yes (source 18.0) | no (source 19.0: no `message_subscribe` in `stock_picking.py`) | - |
| the "package in two places" refusal counts | every quant of the package with a quantity or a reservation, negative ones too (source 16.0 `stock_move._action_done`; the mirror reversal REFUSED, live 2026-10-13) | only quants with a positive quantity (source origin/17.0) | same as 17 (source 18.0) | same as 17 (source 19.0; the mirror reversal ACCEPTED, live 2026-10-13) | - |
| `crm.lead` unarchive: clears `lost_reason_id`, re-scores | in `toggle_active` (source 16.0) | in `toggle_active` (source origin/17.0) | in `toggle_active` (source 18.0) | in `action_unarchive`; no `toggle_active` on the lead (source 19.0) | - |
| `mail.activity` refuses an assignee who cannot read the record when the activity is not automated | yes, `_check_access_assignation` (source 16.0) | method kept but deprecated and not called (source origin/17.0 docstring) | no such method (source 18.0) | no such method (source 19.0) | - |
| `activity_schedule` marks the activity `automated` unless `automated` is passed | yes (source 16.0) | yes (source origin/17.0) | yes (source 18.0) | yes (source 19.0) | - |
| `crm.note` through the lead's `message_post` route (`subtype_xmlid mail.mt_note`), message id read back | not run | not run | not run | live 2026-10-13: applied, verified 1 (`ODOO_OOM_BEHAVIOURS` pointing at a one-route file) | - |
| apply invariants: `probability-manual` and `lot-totals-internal` read around an apply | live 2026-10-13: `crm.tag` apply, 10 open leads follow their automated score before and after (preexisting, not the apply's); `stock.net` t/94 31/31 | not run (unreachable) | live 2026-10-13: `crm.tag` apply, 10 before and after; t/94 31/31 | live 2026-10-13: `crm.tag` apply, 17 before and after; t/94 31/31 on the third run (see TEST-RESULTS: the first two failed when another session moved stock the sum read) | - |
| `res.partner` address written on a company reaches its children of type contact, not those of another type; written on a contact it stays there | live 2026-10-13 (t/92, 28/28) | source origin/17.0 (no upstream step); not live | live 2026-10-13 (t/92, 28/28) | the contact's address is also written on the company: live 2026-10-13 (t/92, 28/28; source 19.0 `_fields_sync` "To UPSTREAM") | - |
| `res.partner` vat written on a company replaces its non-company children's; written on a contact | stays on the contact, live 2026-10-13 | source origin/17.0 (as 16); not live | stays on the contact, live 2026-10-13 | written on the company too (`vat` is a synced commercial field), live 2026-10-13 | - |
| `res.partner` Tax ID check (`base_vat`) on an invalid number | REFUSED at write and create, with or without a country, accepted under `no_vat_validation`, live 2026-10-13 (`base_vat` installed on the local 16 for the run) | not probed | same as 16, live 2026-10-13 (`base_vat` installed for the run) | REFUSED with a country; ACCEPTED when the partner has no country (source 19.0 `_run_vat_checks` returns at once), live 2026-10-13. `base_vat` was already installed there | - |
| `res.partner` `company_type` (writes `is_company`), `commercial_partner_id`, `display_name` "Company, Contact", website `http://`, `email_normalized` lower-cased and a malformed address accepted | live 2026-10-13 (t/92) | not probed | live 2026-10-13 (t/92) | live 2026-10-13 (t/92) | - |
| `res.users.has_group` over RPC (doctor's group test) | a model method: `execute_kw(res.users, has_group, [group])` answers; with ids first it faults "takes 2 positional arguments but 3 were given" (live 2026-10-13, `oom-ops doctor`) | not probed | not probed | a record method: `[[uid], group]` (live 2026-10-13, `oom-ops doctor`) | - |
| `common.db.list` over `/jsonrpc` (LIST_DB) | refused: `odoo.exceptions.AccessDenied`, code 200 (live 2026-10-13, the local cluster, `oom-ops doctor`) | not probed | not probed | refused: `AccessDenied` "Access Denied", code 0 (live 2026-10-13, as 16) | - |
| `/web/login` through the cluster proxy | HTTP 200 with a `Date` header (live 2026-10-13) | not probed | not probed | HTTP 200 with a `Date` header (live 2026-10-13) | - |
| portal user made the way Odoo's portal does (core.user, 0.09): `portal.wizard` create with `partner_ids`, its computed `portal.wizard.user` line, `action_grant_access` on the line; the user's login is the line's email, normalised | live 2026-10-13 (t/35-core-user-live.t 40/40); the wizard exists, `portal.mail_template_data_portal_welcome` | source origin/17.0: as 16 (the modal action loses `view_type`); 17 unreachable, not probed | live 2026-10-13 (40/40); source 18.0: a revoked user is archived and kept in the portal group; the grant always writes `active` and the portal group | live 2026-10-13 (40/40); source 19.0: `group_ids`; the invitation is `auth_signup.portal_set_password_email` sent to the user | - |
| the portal wizard's invitation email | sent at the grant, `force_send`; with no outgoing server the `mail.mail` is left in state `exception` and the grant succeeds, live 2026-10-13 | not probed | same as 16, live 2026-10-13 | a `mail.mail` in state `exception` with no `email_to` (the recipient is the partner), live 2026-10-13 | - |
| `res.users` created with no groups named | gets the template user's groups: the local 16 gives a new user Sales, Inventory, Invoicing, Expenses and Employees administrator groups among others (live 2026-10-13); naming `groups_id` `(6, 0, [base.group_user])` gave a user who cannot read `crm.lead` (t/36-core-attach-live.t) | not probed | not probed | the new user held "Role / User" only (live 2026-10-13) | - |
| `password` written on `res.users` by the administrator over RPC | ACCEPTED; `common.authenticate` with it answers the user's uid, and answers false once the user is archived, live 2026-10-13 | not probed | ACCEPTED, live 2026-10-13 | ACCEPTED, live 2026-10-13 | - |
| API key minting path (core.user `api-key`): a web session as the user; `res.users.apikeys.description` create `{name}` + `make_key` answers the identity-check action (`res.users.identitycheck`, `res_id`); the check reads the password, then `run_check` answers the action `res.users.apikeys.show` whose `context.default_key` is the key. The acting user needs the identity check (10 minutes per session) | the password is written to the wizard's `password` field, then `run_check`; live 2026-10-13 (40/40) | same as 16 (source origin/17.0); not probed | same as 16, live 2026-10-13 (40/40); the wizard adds `duration` and `expiration_date` | the password goes in the call's context (`context.password`; the wizard's `password` field is not stored), then `run_check`; live 2026-10-13 (40/40) | - |
| who may mint an API key | internal users (`user_has_groups('base.group_user')`, source 16.0); a portal user is refused | source origin/17.0: as 16 | source 18.0: `_is_internal()` | source 19.0: `_is_internal()`; live: the plan holds a portal user `not-internal` before any call | - |
| default expiry of a key minted by a user who is not an administrator | none (no expiry field on `res.users.apikeys`), live 2026-10-13 | none (source origin/17.0 `_generate(scope, name)`) | the day after the creation date at midnight (`expiration_date`; the user's groups' `api_key_duration` allows one day), live 2026-10-13 | the same, live 2026-10-13 | - |
| `action_reset_password` on a user with an email, no outgoing mail server | FAILS: "Unable to connect to SMTP Server" (the call sends with `raise_exception`), live 2026-10-13 | not probed | applied, live 2026-10-13 | applied, live 2026-10-13 | - |
| the password-reset route (core.user `reset-take`) | `/web/reset_password`, `auth='public'`; GET with `token` renders `auth_signup.reset_password`: hidden `csrf_token` (bound to the session cookie), `token`, `redirect`, and read-only `login` and `name` with `password` and `confirm_password`; a bad token renders `Invalid signup token` (`invalid_token`) and no fields; POST of those fields runs `res.users.signup(values, token)`, then `do_signup` authenticates the server's session and `web_login` redirects (303 to `/web`). Source 16.0; live 2026-10-16 (t/35-core-user-live.t, t/87-accounts-live.t) | not probed | same route and fields; the token is a signed payload; source 18.0, live 2026-10-16 | the route has `captcha='password_reset'` (passes with no captcha configured); the form asks for `password` and `confirm_password` only: it does not name the user (`login` and `name` are not in the page); POST renders `Your password has been reset successfully.` (200, `do_login=False`, no redirect and no server session). Source 19.0, live 2026-10-16 | - |
| what consumes a reset token | 16: `signup()` writes `signup_token`, `signup_type` and `signup_expiration` to false; a used or unknown token is `Invalid signup token` at the GET; an expired one (24 h after `action_reset_password`) opens the form and is refused at the POST with Odoo's `Signup token '...'` message that the token is not valid (it quotes the token). Live 2026-10-16: a second GET reads `Invalid signup token` | not probed | 18: `signup()` writes `signup_type` false; the token is `hash_sign` of `[partner id, user ids, last login date, signup_type]` with a 4-hour validity (`auth_signup.reset_password.validity.hours`), so it also stops matching once the user signs in or the type is cleared; unknown, used and expired read `Invalid signup token` at the GET. Live 2026-10-16 | 19: as 18, live 2026-10-16 | - |
| `res.partner.signup_url` | a computed char field, readable over RPC by an administrator; after `action_reset_password` it is `<web.base.url>/web/reset_password?db=D&token=T` (the stored token); before one it is `/web/login?db=D&login=L`. The host is `web.base.url`, not the name the proxy answers to. Live 2026-10-16: the same token as the mail | not probed | NOT a field (`Invalid field 'signup_url' on model 'res.partner'`, live 2026-10-16; source 18.0 has only the private `_get_signup_url`): the mail is the only carrier of the link | NOT a field (source 19.0, live 2026-10-16): the mail is the only carrier of the link | - |
| the reset mail on 18 and 19 of the local cluster | n/a (16 has an outgoing server `mailcatcher`) | not probed | no `ir.mail_server`: no mail is sent, so a test makes one pointing at `mailcatcher:1025` for its run and removes it. Live 2026-10-16 | one server, `smtp.example.invalid`: a test adds a lower-sequence server at `mailcatcher:1025` for its run and removes it. Live 2026-10-16 | - |
| `ir.attachment.checksum` and `file_size` | `checksum` is the SHA-1 (hex) of the raw bytes, `file_size` their count; both set at create, live 2026-10-13 (t/36-core-attach-live.t 37/37) | not probed | same, live 2026-10-13 (37/37) | same, live 2026-10-13 (37/37) | - |
| attachment access for a user who cannot read the record the attachment is on (an internal user holding only `base.group_user`, an attachment on a `crm.lead`) | `read` REFUSED: "You are not allowed to access 'Lead/Opportunity' (crm.lead) records" (category access); `search_read` by id answers an empty list; `/web/content/<id>?download=true` with the user's web session answers HTTP 404; an attachment on a partner is read normally. Live 2026-10-13 | not probed | the same checks pass, live 2026-10-13 | `read` REFUSED ("Uh-oh! Looks like you have stumbled upon some top-secret records."), search empty, `/web/content` 404, live 2026-10-13 | - |
| binary path of an attachment | `read` of `datas` over RPC answers base64 of the content; `/web/content/<id>?download=true` with a session cookie answers the bytes (HTTP 200, same SHA-1), live 2026-10-13 | not probed | same, live 2026-10-13 | same, live 2026-10-13 | - |
| two-factor models and methods (`auth_totp`): `res.users.totp_enabled` (boolean, readable by the user and by an administrator), `res.users.totp_secret` (NO_ACCESS: absent from `fields_get`, never readable over RPC), `auth_totp.wizard` (`user_id`, `secret`, `url`, `qrcode`, `code`), `res.users.action_totp_enable_wizard`, `res.users.action_totp_disable` | live 2026-10-13 (t/87-accounts-live.t, t/39-totp.t): all present | not probed (source origin/17.0: the same, `code` a stored wizard field) | live 2026-10-13: all present | live 2026-10-13: all present | - |
| turning two-factor on as the user (core.user `totp`): web session as the user, `action_totp_enable_wizard` answers the identity-check action; `run_check` runs it and answers the `auth_totp.wizard` action (`res_id`); the user reads the wizard's `secret` (base32 in groups of four); `enable` with the RFC 6238 code (HMAC-SHA1, 30 s, 6 digits) | the code is written to the wizard's `code` field, then `enable`; live 2026-10-13 | not probed | same as 16, live 2026-10-13 | the code goes in the call's context (`context.code`; the wizard's `code` is not stored), then `enable`; the password in `run_check`'s context; live 2026-10-13 | - |
| a user with two-factor on: web login with the right password | opens no session: no cookie, no uid (`second_factor`); a wrong password is `credential`; `common.authenticate` by password answers false, live 2026-10-13 | not probed | the same, live 2026-10-13 | the same, live 2026-10-13 | - |
| turning two-factor off (`action_totp_disable`) | refused over `/jsonrpc` ("This method can only be accessed over HTTP"); works over the administrator's own web session with the identity check, live 2026-10-13 | not probed | the same, live 2026-10-13 | the same, live 2026-10-13 | - |
| an API key as the password of `/web/session/authenticate` | REFUSED (credential), live 2026-10-13 (a key minted for a test user) | not probed | REFUSED, live 2026-10-13 | REFUSED, live 2026-10-13 | - |
| removing an API key | an administrator's `unlink` of another user's key is REFUSED ("You are not allowed to delete 'Users API Keys'"); `remove` over `/jsonrpc` is "only accessible over HTTP"; the owner removes it over a web session with the identity check, after which the key is refused by `common.authenticate`, live 2026-10-13 | not probed | the same, live 2026-10-13 | the same, live 2026-10-13 | - |
| the groups field of `res.users` and what a person's read of it holds | `groups_id`, many2many `res.groups`; includes the groups implied by those assigned: the test person (one assigned group, Sales / User: Own Documents Only) reads 7, live 2026-10-13 | not probed | `groups_id`; the same person reads 4, live 2026-10-13 | `group_ids`; holds the groups assigned directly (`all_group_ids` is the closure): the same person reads 1, live 2026-10-13 | - |
| group names for a signed-in person (`res.groups.read` of `full_name`) and group xml ids (`ir.model.data`) | an internal person reads the names ("Sales / User: Own Documents Only"); `ir.model.data` is REFUSED to a person (so `xmlid` is absent); live 2026-10-13 | not probed | the same, live 2026-10-13 | the same, live 2026-10-13 | - |
| group names for a portal user's session | the read of `res.groups` is REFUSED: `session_groups_report` answers the empty list, `groups_readable` 0, live 2026-10-13 | not probed | the same, live 2026-10-13 | the same, live 2026-10-13 | - |
| expiry of a key minted with `duration` 90 by a non-administrator | no expiry field on `res.users.apikeys`: `duration` is ignored, never expires, live 2026-10-13 | not probed | expires at creation + 90 days (2027-01-11), live 2026-10-13 | the same; a longer duration is refused ("You cannot exceed 90.0 days"), live 2026-10-13 | - |
| how groups are grouped (`res.groups`) | `category_id` (many2one `ir.module.category`), `implied_ids`, `rule_groups`, `model_access`; live 2026-10-14 (t/86-roles-live.t) | not probed | as 16, live 2026-10-14 | `category_id` is gone: `privilege_id` (many2one `res.groups.privilege`: `name`, `category_id`, `sequence`, `description`, `placeholder`); `users` is `user_ids`; the name is unique within a privilege; live 2026-10-14 | - |
| `ir.model.data` created over RPC by an administrator (`module` `__oom__`, `model`, `res_id`, `noupdate`) to give a created group, `ir.model.access` row, `ir.rule`, category or privilege an xml id | ACCEPTED, and `ir.model.data` search by module and name finds it; live 2026-10-14 | not probed | ACCEPTED, live 2026-10-14 | ACCEPTED, live 2026-10-14 | - |
| unlinking a record that has an `ir.model.data` row | the row goes with it (no `__oom__` row left after the records were unlinked), live 2026-10-14 | not probed | the same, live 2026-10-14 | the same, live 2026-10-14 | - |
| an administrator creating an `ir.module.category` | REFUSED: `check_access_rights('create')` is false (source: `group_erp_manager` read only); live 2026-10-14 | source origin/17.0: read only | refused, live 2026-10-14 | REFUSED: "You are not allowed to create 'Application' (ir.module.category) records. No group currently allows this operation."; live 2026-10-14 | - |
| an administrator creating a `res.groups.privilege` | - (no such model) | - | - | ACCEPTED (`group_erp_manager` has full access to it); live 2026-10-14 | - |
| a group created over RPC with no category (16, 18) or a privilege with no category (19) | created and assignable by xml id; live 2026-10-14 (t/86-roles-live.t: users held it, the probe passed) | not probed | the same, live 2026-10-14 | the same (the privilege has no category, so the user form's group selection does not offer it, from source: `view_group_hierarchy` lists only privileges of a category); live 2026-10-14 | - |
| a rule domain Odoo cannot read (`ir.rule` create and write) | ValidationError "Invalid domain: ..." from `_check_domain`: an unclosed bracket "'(' was never closed (, line 1)"; an unknown field "Invalid field sale.order.no_such_field_x in leaf ('no_such_field_x', '=', 1)"; an unknown name `NameError: name 'foo' is not defined`; a non-list "Domains to normalize must have a 'domain' form: a list or tuple of domain components"; live 2026-10-14 | not probed | the same; a non-list domain says "'int' object is not iterable"; unknown field "in leaf"; live 2026-10-14 | the same; unknown field "in condition (...)"; a non-list says "Domain() invalid argument type for domain: 2"; live 2026-10-14 | - |
| `ir.rule.global` | readonly, computed from `groups`: a rule written with `groups` is 0; live 2026-10-14 | not probed | the same, live 2026-10-14 | the same, live 2026-10-14 | - |
| what a user holding `base.group_user` and one role group (access rows and a group rule on `sale.order`) can do (t/86-roles-live.t) | the table is what `check_access_rights` says for read, create, write and unlink on product.product, sale.order, sale.order.line, res.partner and the canaries res.users and ir.rule (create refused); reads products and a partner; creates, edits and (once unlink is given) deletes its own draft quotation; its line needs `product_id` ("Missing required fields on accountable sale order line" without one); another user's quotation is not found by `search_read` and is refused on write; creating a product is refused; live 2026-10-14 | not probed | the same checks pass (a line without a product is accepted), live 2026-10-14 | the same checks pass, live 2026-10-14 | - |
| mailing profile (`profiles/mailing/16.yaml`): `mailing.mailing`, `mailing.list`, `mailing.contact`, `mailing.contact.subscription`, `mailing.trace`, `mail.blacklist`, `mail.mail`, `mailing.mailing.test`, `ir.cron`, `ir.cron.trigger`, `res.partner.category`, `mail.message`, and from the second pass `mail.compose.message` and `link.tracker` | live 2026-10-15 (demo16, `core.check --set pack=mailing`): 14 models, 93 fields, none missing (12 models and 79 fields before the second pass) | not probed | not probed | not probed | - |
| `expected` and `total` of a draft mailing | `expected` counts traces, so 0 until a send makes them; `total` is every contact of the lists, opted-out and blacklisted included (`mailing_domain` is `[('list_ids', 'in', [...])]`: for lists Odoo adds no blacklist term); live 2026-10-15 (t/85: `expected` 0, `total` 5). Who will be mailed is therefore worked out from the subscriptions | not probed | not probed | not probed | - |
| `email_from` left unset on `mailing.mailing` create | ACCEPTED: filled from the creating user's formatted email (`"Administrator" <admin@example.com>`), `reply_to_mode` `new` and `reply_to` the same address, so the user must have an email; live 2026-10-15 (t/85) | not probed | not probed | not probed | - |
| the test wizard (`mailing.mailing.test`: `email_to` text, one address per line, `mass_mailing_id`; `send_mail_test`) | sends at once, not through the mail queue, under the mailing's own subject with no prefix, and deletes its `mail.mail` rows afterwards; it makes no `mailing.trace`, so no counter moves; the outcome is logged on the mailing's chatter ("Test mailing successfully sent to ..."), a failure is logged and not raised; the unsubscribe link in it carries `res_id=0`; live 2026-10-15: t/85 asserts the copy in the catcher, its subject, the rewritten link and that no trace is made; the deletion of the wizard's rows (Odoo's log) and the `Reply-To` and `List-Unsubscribe` headers (the catcher) were read during the build, not asserted | not probed | not probed | not probed | - |
| the unsubscribe rewrite | an anchor `href="/unsubscribe_from_list"` is rewritten at send time to `<web.base.url>/mailing/<id>/confirm_unsubscribe?res_id=<contact>&email=<address>&token=<hash>`, and a `List-Unsubscribe` one-click header (`/mail/mailing/<id>/unsubscribe_oneclick?...`) is added; a body with no such anchor goes out with no way to opt out. Live 2026-10-15 (t/85, from the catcher's copies) | not probed | not probed | not probed | - |
| who may create `mail.blacklist` rows | an administrator (Settings) and an Email Marketing user (`ir.model.access`: create, write, unlink for both); an administrator created, unarchived (`active` write) and unlinked rows; `create` returns the existing row for an address already listed and normalises the address; live 2026-10-15 (t/85) | not probed | not probed | not probed | - |
| `mailing.contact` and its subscriptions | created with `subscription_list_ids` as a one2many create (one subscription per list); `email_normalized` lower-cased and `is_blacklisted` follow the blacklist; setting `opt_out` on a subscription stamps `unsubscription_date`; an address typed in capitals is stored as typed and matched by `email_normalized`; live 2026-10-15 (t/85) | not probed | not probed | not probed | - |
| a send's traces for an opted-out, a blacklisted and a repeated address | opted out of every list it is on: trace `cancel`, `failure_type` `mail_optout`, no mail goes out (the trace may carry the id of the cancelled `mail.mail`, live 2026-10-16); blacklisted: `cancel`, `mail_bl`; the counters then read `sent` 3, `canceled` 2, `expected` 5 for 5 contacts (live 2026-10-15, t/85); a second contact with an address already mailed is `cancel` `mail_dup` (source only, not run live) | not probed | not probed | not probed | - |
| `action_send_mail` on a draft | makes a trace and a `mail.mail` per recipient and hands the mails to the mail server itself in the same call; the mailing ends `done`; a delivered mass mail deletes its `mail.mail` row, so the queue is empty after (t/85: five messages in the catcher, five `sent` traces, `queue` empty); live 2026-10-15 | not probed | not probed | not probed | - |
| `action_put_in_queue` and the cron | the state becomes `in_queue` and a one-off `ir.cron.trigger` is made for the mass-mailing queue cron, due at once (at `schedule_date` for a scheduled mailing); a running cron worker answers it within seconds, so the daily interval (`ir_cron_mass_mailing_queue`: every 1 days; `ir_cron_mail_scheduler_action`: every 1 hours) matters only with no cron worker; t/85: a mailing queued without `now` was `done` within 30 s, one scheduled five days ahead stayed `in_queue` with its trigger at the schedule date. Every mailing create also makes triggers for the (inactive) A/B-testing cron | not probed | not probed | not probed | - |
| `action_put_in_queue` then `action_send_mail` in one request | RACES the cron worker: the worker starts the queue job within milliseconds of the queueing and sends the same mailing in its own transaction; one recipient was mailed twice and the loser logged "could not serialize access due to concurrent update". Observed once on demo16 on 2026-10-15 while building the pack (not a test); `mailing.send now=1` therefore sends the draft directly and never queues it first | not probed | not probed | not probed | - |
| `ir.cron.method_direct_trigger` | runs the job in the caller's request: a queued mailing whose `schedule_date` was moved into the past (so no trigger was made for it) stayed `in_queue` for five seconds, then one `method_direct_trigger` of `mass_mailing.ir_cron_mass_mailing_queue` (found through `ir.model.data`) left it `done` with `sent` 3 when the call returned; it takes every due queued mailing, not only the one named; live 2026-10-15 (t/85, `mailing.process`) | not probed | not probed | not probed | - |
| `=ilike` and the LIKE wildcards | the value is a LIKE pattern: `_` and `%` are wildcards (`OOMRn_a@x` matched `OOMRnXa@x`, `OOMRn%@x` matched it too); a backslash escapes either (`OOMRn\_a@x` matched only an underscore, and still folded case against `OOMRn_A@OOM.example`); live 2026-10-15 (t/84, evidence grade: live) | not probed | not probed | not probed | - |
| `ir.model.fields` for inbound references | `relation`, `ttype`, `on_delete` (`set null`, `cascade`, `restrict`, empty for many2many) and `store` answer a search by `relation`: 83 stored many2one/many2many fields point at `res.partner` here; `crm.lead.partner_id` is `set null`, `res.partner.category.parent_id` is `cascade`; a `many2one_reference` field (`res_id`: `mailing.trace`, `calendar.event`, `mail.message`, ...) has no `relation` and no `relation_field`, so the model name beside it (`model` or `res_model`) is by convention; live 2026-10-15 (t/84, evidence grade: live) | not probed | not probed | not probed | - |
| `read` of a deleted id | `read([id], ['id'])` returns `[{id}]` without touching the database; `read([id], ['display_name'])` returns `[]`; so absence is read with `display_name`; live 2026-10-15 (probe, then t/84, evidence grade: live) | not probed | not probed | not probed | - |
| `action_cancel` | a queued mailing returns to `draft`, `schedule_type` `now`, `schedule_date` cleared; live 2026-10-15 (t/85) | not probed | not probed | not probed | - |
| open and click tracking | a GET of `/mail/track/<mail id>/<token>/blank.gif` through the instance answers 200 and the trace becomes `open` (`opened` 1); a GET of the tracked link `/r/<code>/m/<trace id>` answers 301 to the real address with `utm_` parameters and `clicked` becomes 1; the mail's tracking image and tracked link use `web.base.url`; live 2026-10-15 (t/85) | not probed | not probed | not probed | - |
| a mail left on the catcher by Odoo 16 | `From` read `notifications@example.com` (the system sender) while the mailing's `email_from` was `admin@example.com`; `Reply-To` stayed the mailing's; live 2026-10-15 (cause not isolated) | not probed | not probed | not probed | - |
| the `From` of a mass mail after Odoo's sender rewrite | read from the 16.0 source (`ir_mail_server.py` `_find_mail_server`, `_prepare_email_message`; `mail_mail.py` `_split_by_mail_configuration`) and checked on demo16 (one server `mailcatcher` with no `from_filter`, `mail.default.from` = `notifications`, `mail.catchall.domain` = `example.com`): the active servers are tried in sequence order for a `from_filter` equal to the author's address, then to the author's domain (the author stands); else one whose `from_filter` covers the default sender (`mail.default.from` if it holds an `@`, else `<mail.default.from>@<mail.catchall.domain>`); else the first server with no `from_filter`, else the first server. In the last three the mail goes as the default sender and `encapsulate_email` keeps the author's name (or the local part of the address) as the display name: `"Administrator" <notifications@example.com>`; with no default sender the author stands. `Reply-To` is not touched by it. `mailing.preview` computes `sent_from` from this; live 2026-10-15: `t/85` asserts the caught mail's `From` address and name equal `sent_from` and the test mail left from the same address. Not asserted: the cases with a `from_filter` (read from the source, proved offline in `t/42` on the fake) and a server-less instance (odoo-bin settings) | not probed | not probed | not probed | - |
| an id with no row, and an archived mailing, in the pack | `mailing.status` and `mailing.preview` of an id that does not exist and `mailing.contacts` of a list id that does not exist are refused (`unknown-mailing`, `unknown-list`), and a mailing read without `archived=1` is refused `archived`: kind `refused`, exit 1, not `usage`; live 2026-10-15 (`t/85`, an id 100000 above the highest) | not probed | not probed | not probed | - |
| `ir.cron.trigger` | present on 16 with `cron_id` and `call_at`; the pack reads it for `queue_due` and the live test removes the ones its stamp made; live 2026-10-15 | not probed | not probed | not probed | - |
| rendering one recipient's mail over RPC | the `mail.render.mixin` methods are private (`mailing.mailing._render_field` and `_get_unsubscribe_url` answer "Private methods ... cannot be called remotely"), but `mail.compose.message.get_mail_values(res_ids)` is public and is the method Odoo's own send calls per recipient. A transient composer made as `action_send_mail` makes it (`composition_mode` `mass_mail`, `model` `mailing.contact`, `mass_mailing_id`, `mailing_list_ids`, `body`, `subject`, `email_from`, `reply_to_force_new`), asked with `context.active_ids` for one contact, returns `subject`, `email_from`, `reply_to`, `email_to`, `body` (the rendered body with links absolute) and `body_html` (inside the mass-mailing layout), plus the `mailing_trace_ids` create command it would make. It creates no `mail.mail`, no `mailing.trace` and no `link.tracker`; so `mailing.preview` is `rendered_by: odoo` for the subject, sender, reply-to and HTML. Live 2026-10-15 (t/85 preview before and after a send; the previewed HTML equals the caught mail's but for the unsubscribe token, the shortened tracked link and the tracking image) | not probed | not probed | not probed | - |
| what a preview cannot carry | the unsubscribe URL's token is `hmac.sha512(database.secret, repr((dbname, mailing id, res_id, email)))` and the tracking URL's token an HMAC under the same secret, both computed in private methods at send; OOM does not read `database.secret`, so the preview shows the real URL shape with the token left as a marked placeholder. The composer's `body` keeps `<base>/unsubscribe_from_list` unrewritten (the rewrite is in `mail.mail._send_prepare_values`, at send); tracked links are shortened only when the composer runs with the mailing's `post_convert_links` context, which makes `link.tracker` rows, so a preview leaves them as written; the tracking image is appended to the sent body by `mail.mail._send_prepare_body`. Source 16.0 (mass_mailing mail_mail.py, mailing.py); live 2026-10-15 | not probed | not probed | not probed | - |
| the plain-text part of a sent mailing | Odoo derives it from the HTML at send time and the unsubscribe rewrite reaches the HTML part only, so the text part keeps the raw `<base>/unsubscribe_from_list` URL; seen in the caught mail of a test send (live 2026-10-15) and kept by `mailing.preview`'s derived text and `mailing.create`'s plan note. The text is derived by OOM (a close imitation of `html2plaintext`), not rendered by Odoo | not probed | not probed | not probed | - |
| `get_base_url` on `mailing.mailing` | public over RPC; returns `web.base.url` (`https://ai-dev:8443` on demo16, which is not the host name the ops config reaches it by); live 2026-10-15 (probe, then t/85) | not probed | not probed | not probed | - |
| `link.tracker` for a mailing | rows (`url`, `short_url` `<base>/r/<code>`, `count`, `mass_mailing_id`) exist only after a send (none after a preview or a test); the click path for a recipient is `short_url` + `/m/<trace id>`, which answered 301 and moved `clicked` and the link's `count` to 1 (t/85, built from `mailing.preview` and `mailing.status` alone and equal to the link in the caught mail). A second click on another recipient's trace from the same address did not raise `clicked` (observed in the first run of this pass, when the test did it; not asserted: Odoo counts one click per address and link). Live 2026-10-15 | not probed | not probed | not probed | - |
| `mailing.trace.mail_mail_id` after delivery | cleared when Odoo deletes the delivered mass mail, so `mailing.status traces=1` has no `mail_id` for a sent trace; the field is set while the mail is waiting, failed or cancelled. Live 2026-10-15 (t/85 asserts the absence after a send; the presence is asserted offline only) | not probed | not probed | not probed | - |
| `unlink` on `mailing.mailing` | allowed for the administrator on a draft and on a `done` mailing with traces (`in_queue` and `sending` not probed); the traces go with it (`mailing.trace.mass_mailing_id` is `ondelete='cascade'`: five traces before, none after). So a sent mailing's record of who was mailed is destroyed by a delete, which is why `mailing.delete` deletes drafts only and holds the rest as `sent-kept`. Live 2026-10-15 (t/85: a stamped draft deleted through `mailing.delete`, a done mailing unlinked raw) | not probed | not probed | not probed | - |
| `active` on `mailing.mailing` | writable on a `done` mailing (other states not probed); false takes the mailing out of the default `search_read` (it is read by id, or with `active in [true, false]`) and out of the queue cron's search, and keeps its traces (five) and counters; true restores it. Live 2026-10-15 (t/85: a done mailing archived, read with `archived=1`, restored) | not probed | not probed | not probed | - |
| where the blacklist reason lives | on the `mail.blacklist` row's own thread as a `mail.message` and nowhere else: `message_post(body="Blacklisting Reason: ...", message_type="comment", subtype_xmlid="mail.mt_note")` (what `mailing.blacklist` posts; Odoo's own remove-with-reason posts "Unblacklisting Reason: ...") reads back as a `comment` with an HTML body (`<p>Blacklisting Reason: ...</p>`), subtype Note, author the acting user. The row has no reason field. Creating a row also posts a `notification` "Mail Blacklist created", so a thread holds that and the reason (two messages), and `mailing.blacklisted` takes the last message whose text begins with either reason prefix. Live 2026-10-15 (t/85 third pass, demo16) | not probed | not probed | not probed | - |
| `unlink` on `mailing.contact` | allowed for the administrator; the contact's `mailing.contact.subscription` rows go with it (`contact_id` is `ondelete='cascade'`: two subscriptions before, none after) and the lists stay; `mailing.trace` rows that pointed at it (`res_id`, model `mailing.contact`; `res_id` is no foreign key) stay with their `email` and the old id, so they lose the contact and nothing refuses the delete; its address's `mail.blacklist` row is untouched. Live 2026-10-15 (t/85 third pass, `mailing.delete contact=` and `email=`) | not probed | not probed | not probed | - |
| `unlink` on `mailing.list` | allowed for the administrator on a list a draft mailing names; the list's subscription rows go with it (`list_id` is `ondelete='cascade'`) and the contacts stay; the mailing stays and drops the list from `contact_list_ids` (the many2many row cascades). Odoo does not refuse a list a mailing uses; `mailing.delete` holds it `in-use` unless `force=1`. Live 2026-10-15 (t/85 third pass) | not probed | not probed | not probed | - |
| a revert of a contact or list delete | the runner holds a plain `unlink` as irreversible, so `mailing.delete` plans a `custom` change whose revert is a create: a contact is recreated with `subscription_list_ids` as `[0, 0, { list_id, opt_out }]` commands and comes back on its lists, opted out where it was (the opt-out date is Odoo's, the revert's); a list is recreated with `subscription_ids` as `[0, 0, { contact_id, opt_out }]` commands. Both get new ids. Not restored: the traces that pointed at the old contact id, and the list a mailing lost under `force=1`. Live 2026-10-15 (t/85 third pass) | not probed | not probed | not probed | - |
| `write_date` and `create_date` on `mailing.mailing` and `create_date` on `mail.blacklist` | read by `search_read` as `YYYY-MM-DD HH:MM:SS` UTC text; `mailing.status` returns the mailing's two as `write_date` and `create_date` and `mailing.blacklisted` the blacklist row's as `created`. Live 2026-10-15 (t/85 third pass) | not probed | not probed | not probed | - |
| a `many2one_reference` after its record is unlinked (`mailing.trace.res_id`) | Odoo does not clear it: after the contacts were unlinked by a revert, the traces still carried their `res_id` (`contact_id` 118, 119, 120 in `mailing.status traces=1`) and their `email`, and the mailing read `recipients: 0` with `expected: 3`, `sent: 3`, `delivered: 3`. Graded: observed in a read on 2026-10-15 (stamp `t2-1309`), not provoked by a test of its own; t/83 asserts `recipients_now` 0 and `sent` 5 after a cleanup. The wording of the plan effect follows it: `N traces of mailing M keep its id and email; the contact is gone` | not probed | not probed | not probed | - |
| the report route: `/report/<converter>/<reportname>` and `/report/<converter>/<reportname>/<docids>` (`web/controllers/report.py`, `report_routes`; `converter` `pdf`, `html`, `text`), `type='http'`, `auth='user'`: it renders and answers the document in the same response (`Content-Type` `application/pdf` with `Content-Length`; `text/plain` for text; the default `text/html` for html). 19 adds `readonly=True` | source 16.0; live 2026-10-15 (t/48-core-report-live.t, 50/50): `/report/pdf/sale.report_saleorder/<id>` with a web session answers HTTP 200, `%PDF-`, 25 KB for an empty quotation; `/report/html/...` answers HTML | source 17.0: the same route (`auth='user'`), render method private (`_render_qweb_pdf`), `get_wkhtmltopdf_state` public; not probed live | source 18.0 (`readonly=True`); live 2026-10-15 (t/48-core-report-live.t 50/50; 28 KB) | source 19.0 (same route, `readonly=True`); live 2026-10-15 (t/48-core-report-live.t 50/50; 27 KB) | - |
| the report route without a session | HTTP 303 to `/web/login?redirect=...` (no redirect followed; a login redirect where a pdf was expected is the session gone), live 2026-10-15 | not probed | live 2026-10-15 | live 2026-10-15 | - |
| the render method over RPC: `ir.actions.report._render_qweb_pdf` | private since 16: "Private methods (such as 'ir.actions.report._render_qweb_pdf') cannot be called remotely", live 2026-10-15 (source `ir_actions_report.py`); no public name exists (`render_qweb_pdf` does not exist), so no RPC transport can render and `core.report` needs a web session | not probed | the same, live 2026-10-15 | the same, live 2026-10-15 | - |
| the web session store | source 16.0: `FilesystemSessionStore` under `session_dir` (a file per session in the data directory of the host that made it), so a request that lands on another host without a shared session directory is answered with a login redirect; not provoked on the single-host cluster | not probed | not probed | source 19.0: the same class | - |
| a report with `attachment` set stores its rendered PDF as an `ir.attachment` on the record when the route renders it (`_render_qweb_pdf` creates it, an `AccessError` is only logged); `attachment_use` makes a later render reload it by the name the `attachment` expression gives (`retrieve_attachment`) | source 16.0; live 2026-10-15: a report with a plain `attachment` name and `attachment_use` stored `OOM-<stamp>.pdf` on the partner at the first render and a second render reloaded the same attachment; an expression that is Python (`'OOMx-<stamp>-%s.pdf' % object.id`) stored too | not probed | live 2026-10-15, the same | source 19.0 (same code); live 2026-10-15, the same | - |
| a report that has `attachment` set whose template lacks `data-oe-model` and `data-oe-id` on the div of class `article` | the route answers HTTP 400 with Odoo's error page, whose "Error message" says "Can not separate file to save as attachment because the report's template does not contains the attributes 'data-oe-model' and 'data-oe-id' on the div with 'article' classname", live 2026-10-15 (found building the live test; a template without `attachment` set renders without them) | not probed | HTTP 400 with the same reason (Odoo 18 words it "Cannot separate file ..."), live 2026-10-16 (t/48-core-report-live.t: `core.report` answers a `fault` carrying Odoo's message) | HTTP 422 Unprocessable Entity with that reason, live 2026-10-16 (the same test) | - |
| `ir.actions.report.get_wkhtmltopdf_state` over RPC (`@api.model`, public) | answers `ok` on the local cluster, live 2026-10-15 (doctor `server.wkhtmltopdf`, t/48-core-report-live.t); the states are `install`, `upgrade`, `ok`, `workers`, `broken` (source docstring) | not probed | answers `ok`, live 2026-10-15 | answers `ok`, live 2026-10-15 | - |
| `ir.actions.report` fields read by `core.reports`: `name`, `report_name`, `report_type`, `model`, `attachment`, `print_report_name`, `binding_model_id`, and `attachment_use` where the series has the field | live 2026-10-15 (t/48-core-report-live.t: `core.reports --set model=sale.order` lists `sale.report_saleorder` and `sale.report_saleorder_pro_forma`, `binding` true) | not probed | live 2026-10-15 | live 2026-10-15 | - |
| a web session that Odoo has dropped, met by an RPC call | `/web/dataset/call_kw` answers the fault `odoo.http.SessionExpiredException` (category `session`) before the method runs, so the call may be sent again on a new session; live 2026-10-15 (t/48-core-report-live.t: the session signed out at Odoo through a second handle, then `core.reports`) | not probed | live 2026-10-15 | live 2026-10-15 | - |
| which invoice report the account.move Print menu binds (`binding_model_id`) | live 2026-10-15 (t/48-core-report-live.t): `account.report_invoice`, `account.report_invoice_with_payments` and `account.report_original_vendor_bill` | not probed | `account.report_invoice` and `account.report_original_vendor_bill` only; `account.report_invoice_with_payments` exists with no binding | all three, as 16 | - |
| the invoice report's stored copy | live 2026-10-15: `attachment` is `object._get_report_attachment_filename()`, `attachment_use` off; the first render of a posted invoice stores `INV_2026_00005.pdf` on the move (the number with `/` as `_`); a second render makes no new copy while it exists (the row's `stored` is absent) and the rendered bytes differ from the kept copy | not probed | live 2026-10-15: `attachment` empty, no copy stored | live 2026-10-15: `attachment` empty, no copy stored | - |
| whether sale's and purchase's reports store copies | live 2026-10-15: `sale.report_saleorder` and, once `purchase` was installed, `purchase.report_purchaseorder` and `purchase.report_purchasequotation` have `attachment` empty: none stores | not probed | the same, live 2026-10-15 | the same, live 2026-10-15 | - |
| the original vendor bill report, `account.report_original_vendor_bill` | not probed | not probed | live 2026-10-16 (a draft bill): `attachment` is `'original_vendor_bill.pdf'` and `attachment_use` true; with no main attachment the route answers HTTP 400 "No original purchase document could be found for any of the selected purchase documents.", which `core.report` prints as a `fault` carrying it; a PDF attached with `core.attach` is not the bill's `message_main_attachment_id` and the answer is the same; set through `core.import` (`lookup` `name`), the render returns Odoo's rewrite of the PDF (36985 bytes for a 29312-byte source) and leaves no copy on the record, so `source=attachment` is `refused/no-stored-copy` | not probed | - |
| the printed title of a confirmed order | live 2026-10-15 (the `h2` of the html render): a `sale.order` reads `Quotation # S00080` in draft and `Order # S00080` after `action_confirm` (state `sale`); a `purchase.order` reads `Request for Quotation P00001` (`purchase.report_purchasequotation`) in draft and `Purchase Order # P00001` after `button_confirm` (state `purchase`, `purchase.report_purchaseorder`) | not probed | the same, live 2026-10-15 | the same, live 2026-10-15 | - |
| deleting a cancelled invoice and a confirmed order | live 2026-10-15: a posted `account.move` put back to draft (`button_draft`), cancelled (`button_cancel`) and unlinked is deleted, as are a confirmed sale order (cancelled with `disable_cancel_warning`; the plain `action_cancel` returns a wizard and cancels nothing) and purchase order; no record stays | not probed | the same; as on 16, `sale.order.action_cancel` of a confirmed order returns Odoo cancel wizard and cancels nothing unless the context has `disable_cancel_warning` | the same as 16 (no wizard seen) | - |
| the stored copy of a draft invoice, once the invoice is posted | live 2026-10-15 (t/48-core-report-live.t): the first render of a draft `account.move` through `account.report_invoice_with_payments` stored a copy (its `create_date` is on the row as `stored_at`); after `action_post` `source=auto` returned the same attachment, so Odoo keeps the draft's copy and does not refresh it after posting (the record's `write_date` is later than the copy's `create_date`) | not probed | not applicable: the invoice report stores no copy (`attachment` empty); the test skips | not applicable: the invoice report stores no copy; the test skips | - |
| `core.import` of `sale.order.line` keyed by `order_id,product_id` (order by name, product by name) | live 2026-10-15 (t/96-core-import-live.t): two lines of one order are two creates, applied and read back; the re-run is all `unchanged`; `existing records considered` counts only the lines of the orders the rows name; a `one2many` in a row is refused `usage` | not probed | not probed | the same, live 2026-10-15 | - |
| the state of `sale.order`, `purchase.order` and `account.move` | `readonly` in `fields_get` on all three models; moved by Odoo's methods only (`action_confirm`/`action_cancel`/`action_draft`; `button_confirm`/`button_cancel`/`button_draft`; `action_post`/`button_draft`/`button_cancel`). States: sale `draft sent sale done cancel`, purchase `draft sent to approve purchase done cancel`, move `draft posted cancel`. Live 2026-10-15 (the `readonly` flag and the selections read with `fields_get` by a probe, not a test; the transitions below by t/49-documents-pack-live.t) | not probed | sale `draft sent sale cancel` (no `done`; the lock is the `locked` flag); purchase and move as 16. Live 2026-10-15 | sale `draft sent sale cancel` and purchase `draft sent to approve purchase cancel` (no `done`; `locked` on both); move as 16. Live 2026-10-15 | - |
| `sale.order.action_confirm` | draft or sent to `sale`; `date_order` set; a delivery for the goods line: **two** pickings (a pick, state `confirmed`, and an out, state `waiting`) on the demo warehouse; the service line makes none; no invoice. The 16 setting `group_auto_done_setting` would end the order in `done` (source; not set on the demo). Live 2026-10-15 (t/49-documents-pack-live.t 108/108) | not probed | one delivery picking (`confirmed`); no `done`. Live 2026-10-15 (110/110) | one delivery picking (`confirmed`); no `done`; confirming sets `locked` only when the company setting says so (source). Live 2026-10-15 (111/111) | - |
| `sale.order.action_cancel` of a confirmed order | without the context key `disable_cancel_warning` it returns the `sale.order.cancel` wizard (an `ir.actions.act_window`) and cancels nothing, state stays `sale`; with the key the order is `cancel` and every delivery it made is `cancel`. Live 2026-10-15 (t/49) | not probed | the same. Live 2026-10-15 | no wizard: the order is cancelled at once, with or without the key. Live 2026-10-15 | - |
| a locked order (`locked` true) cancels | not applicable (16 has the state `done`, not probed: the demo does not lock on confirmation) | not probed | `action_cancel` raises `You cannot cancel a locked order. Please unlock it first.` before the wizard; `action_lock` and `action_unlock` set the flag. Live 2026-10-15 | the same. Live 2026-10-15 | - |
| `sale.order.action_draft` and `unlink` | `action_draft` works from cancel and sent only; `unlink` is refused for a confirmed order (`You can not delete a sent quotation or a confirmed sales order. You must first cancel it.`) and allowed for a draft (no cancel needed) and for a cancelled order, whose cancelled deliveries stay with the order's name as `origin`. Live 2026-10-15 (t/49) | not probed | the same. Live 2026-10-15 | the same. Live 2026-10-15 | - |
| `purchase.order.button_confirm` | draft or sent to `purchase` (`to approve` under double validation, not provoked: the demo administrator holds the manager group and approves at once); one receipt (`assigned`) for the goods line; a `product.supplierinfo` line for the vendor is added to the product (one), and it stays after a cancel or the undo of the confirm. Live 2026-10-15 (t/49) | not probed | the same. Live 2026-10-15 | the same. Live 2026-10-15 | - |
| `purchase.order.button_cancel`, `button_draft` and `unlink` | `button_cancel` makes the order `cancel` and its receipt `cancel`; `button_draft` returns a cancelled order to `draft`; `unlink` is refused unless the order is `cancel` (`In order to delete a purchase order, you must cancel it first.`), and the cancelled receipt stays with the order's name as `origin` and keeps the product from being deleted (`stock_move_product_id_fkey`). Live 2026-10-15 (t/49) | not probed | the same. Live 2026-10-15 | the same; `button_cancel` of a locked order raises `Unable to cancel purchase order(s): ... You must first unlock them.` (`button_lock`, `button_unlock` set the flag). Live 2026-10-15 | - |
| `account.move.action_post`, `button_draft`, `button_cancel` | a draft invoice reads name `/` before it is posted; `action_post` makes it `posted` with the journal's number (`INV/2026/00005`); `button_draft` makes it `draft` again and the name stays (the number stays consumed; posting again reuses it, which the `account.draft` revert proves); `button_cancel` of a draft makes it `cancel`, and `button_draft` of a cancelled move returns it to `draft`. `button_cancel` on a posted move is not used: 16 writes `cancel` on it without unposting. Live 2026-10-15 (t/49) | not probed | the name of a draft reads empty (false), not `/`; the number is `INV/2026/00002`; the rest as 16. Live 2026-10-15 | the name of a draft reads empty; number `INV/2026/00011`; the rest as 16. Live 2026-10-15 | - |
| `account.move` `unlink` after the state moves | refused while posted (`You cannot delete an item linked to a posted entry.`); deleted after `button_draft` even though it was posted once (the audit trail setting is off on the demo; with `check_account_audit_trail` (18) or `restrictive_audit_trail` (19) on, the source refuses a move posted once, not provoked). Live 2026-10-15 (t/49) | not probed | refused while posted (`You can't delete a posted journal item. Don't play games with your accounting records; reset the journal entry to draft before deleting it.`); deleted after `button_draft`. Live 2026-10-15 | the same message; deleted after `button_draft`. Live 2026-10-15 | - |
| `sale.order.line` `unlink` | refused while the order is `sale` or `done` (`_unlink_except_confirmed`: "You can not remove an order line once the sales order is confirmed"); allowed from `draft`, `sent`, `cancel`; a section or note line (`display_type`) and a down payment line never invoiced are always allowed. Source 16.0; live 2026-10-16 (t/49: refused on a confirmed order, deleted after `sale.cancel`) | not probed | refused while the order is `sale` (no `done` state; the lock is a flag), same exceptions. Source 18.0; live 2026-10-16 | the same as 18. Source 19.0; live 2026-10-16 | - |
| `purchase.order.line` `unlink` | refused while the order is `purchase` or `done` (`_unlink_except_purchase_or_done`: "Cannot delete a purchase order line which is in state ..."); allowed from `draft`, `sent`, `to approve`, `cancel`. Source 16.0 (purchase.py); live 2026-10-16 (t/49) | not probed | the same, sections and notes (`line_section`, `line_note`) exempt. Source 18.0; live 2026-10-16 | refused only while the order is `purchase` (`_unlink_except_purchase`; there is no `done` state, the lock is a flag), sections, subsections and notes exempt. Source 19.0; live 2026-10-16 | - |
| `account.move.line` `unlink` | refused when any of the lines' moves is `posted` (`_unlink_except_posted`: "You cannot delete an item linked to a posted entry."), also a tax or payment-term line (`dynamic_unlink` context lifts it) and a reconciled line; allowed from `draft` and `cancel`. Source 16.0; live 2026-10-16 (t/49: refused on a posted move, deleted after `button_draft`) | not probed | refused only for a posted move's non-zero lines (balance or amount in currency), "You can't delete a posted journal item. ... reset the journal entry to draft before deleting it."; a hashed move (`inalterable_hash`) refuses all its lines. Source 18.0; live 2026-10-16 | the same as 18. Source 19.0; live 2026-10-16 | - |
| the states in each behaviour file's `unlink_requires`, checked against the source (primitives-6, 2026-10-16) | `sale.order`: `_unlink_except_draft_or_cancel` refuses any state but `draft` and `cancel` (a `sent` quotation too), so the header's "draft or cancel" is right; its lines refuse only while the order is `sale` or `done`, so "draft or sent or cancel" is right and the two lists differ because the two rules differ. `purchase.order`: `_unlink_if_cancelled` refuses all but `cancel`. `purchase.order.line`: refused while the order is `purchase` or `done`, so draft, sent, to approve and cancel. `account.move`: the model has no state check of its own (`unlink` removes the lines first); the refusal is the line's, on a `posted` move, so "draft or cancel" holds; a move once posted is also refused when the company's audit trail is on, whatever its state now (not provoked). No list needed a correction. Source 16.0 (sale.order, purchase.py, account.move, account.move.line) | not probed | the same rules, sources 18.0 (`purchase_order.py`, `purchase_order_line.py`; sections and notes exempt on a purchase line) | the same, source 19.0 (a purchase line is refused only while the order is `purchase`; sale lines only while `sale`) | - |
| the refusal a revert's planned delete meets at apply, with the parent confirmed or posted (the run reads `failed`; `resume` finishes it after `sale.cancel`, `purchase.cancel` or `account.draft`) | `purchase.order`: "In order to delete a purchase order, you must cancel it first."; a sale line: "You can not remove an order line once the sales order is confirmed."; a purchase line: "Cannot delete a purchase order line which is in state 'Purchase Order'."; a move line: "You cannot delete an item linked to a posted entry." Live 2026-10-16 (t/49-documents-pack-live.t) | not probed | the same purchase order and purchase line words; a sale line: "Once a sales order is confirmed, you can't remove one of its lines (we need to track if something gets invoiced or delivered)."; a move line: "You can't delete a posted journal item. Don't play games with your accounting records; reset the journal entry to draft before deleting it." Live 2026-10-16 | the same as 18. Live 2026-10-16 | - |
| what bumps `res.partner.customer_rank` / `supplier_rank` | posting an invoice or bill (`account.move._post` calls `_increase_rank` on the partner and its commercial partner); also a partner created under the `res_partner_search_mode` context. A sale or purchase confirm moves no field of the partner: a snapshot of every stored scalar field of the partner before and after `action_confirm` / `button_confirm` differed in nothing, and after `action_post` only `customer_rank` (0 to 1; on 19 also `write_date`). Live 2026-10-16 (tmp probe on a stamped partner, removed), source 16.0 / 18.0 / 19.0 account partner.py, account_move.py. A partner with an invoice posted read `1 -> 2` (live 2026-10-16); the behaviour file lists the rank and mail/activity bookkeeping fields as `volatile` | not probed | as 16 (live 2026-10-16) | as 16 (live 2026-10-16) | - |
| `action_archive` and `action_unarchive` over RPC on `res.partner` (the archive of `core.archive`) | accepted, `active` reads back false and true, live 2026-10-16 (t/50-core-archive-read-live.t) | not probed | same, live 2026-10-16 (t/50-core-archive-read-live.t) | same, live 2026-10-16 (t/50-core-archive-read-live.t) | - |
| `action_archive` on a partner that has a contact (`parent_id`) | the contact stays active, live 2026-10-16 (t/50-core-archive-read-live.t) | not probed | same, live 2026-10-16 (t/50-core-archive-read-live.t) | same, live 2026-10-16 (t/50-core-archive-read-live.t) | - |
| `res.country` has an `active` field | no, so `core.archive` holds it `no-active-field`, live 2026-10-16 (t/50-core-archive-read-live.t) | not probed | same, live 2026-10-16 (t/50-core-archive-read-live.t) | same, live 2026-10-16 (t/50-core-archive-read-live.t) | - |
| what `mass_mailing_sale` and `mass_mailing_crm` add to `mailing.mailing` | `sale_quotation_count` and `sale_invoiced_amount` (Integer, not stored, `@api.depends('mailing_domain')`; the compute reads `sale.order` and `account.move` through `.sudo()._read_group`), `crm_lead_count` (Integer, not stored; reads `crm.lead` through `.sudo()` with `active_test` off) and `use_leads` (Boolean, `has_group('crm.group_use_lead')`). Because they are computed fields, a `search_read` or `read` that names no fields computes all of them; the filing of 2026-10-16 (office.xisl.com, 16.0-20250909) saw that read fault on `account.move` for a user without accounting rights, and `mailing.status` and every other read of the pack now name their fields. On demo16 the unnamed read does not fault for a user with the mass-mailing group only: `sale_invoiced_amount` and `crm_lead_count` named, and a read with no `fields`, both answered, so the computes ran as sudo in that build; the filing's fault came from another field, `total`, on a partner-domain mailing (the next row). Source 16.0 (mass_mailing_sale and mass_mailing_crm mailing_mailing.py, read in the container); live 2026-10-16 (t/85 operator block, demo16, `mass_mailing_sale` and `mass_mailing_crm` installed) | not probed | not probed | not probed | - |
| the rights each computed field of `mailing.mailing` needs, and the one that faulted for a mailing operator | `total` is the field: `_compute_total` calls `_get_recipients()`, which searches the mailing's target model with its `mailing_domain` as the reading user (no `sudo`), so a mailing on `res.partner` with the domain `[('invoice_ids.state', '=', 'posted')]` makes Odoo check `account.move` and refuses a user without Accounting/Billing, Sales/User: Own Documents Only or Purchase/User. A read of that mailing's `total` faults (`You are not allowed to access 'Journal Entry' (account.move) records.`); every other field reads for the mass-mailing user, the counters among them (`_compute_statistics` reads `mailing.trace`, which the group may read). Read with the other mailings in one `search_read` the fault is the whole read's, which is why `mailing.status` with no filter faulted and a read of one list mailing did not. A mailing to `mailing.contact` has no such domain reach. Live 2026-10-16 (demo16, reproduction as a user with only `mass_mailing.group_mass_mailing_user` on a draft mailing stamped `m5r-1016` on `res.partner`, then `t/85-mailing-live.t` operator block): `total` was the only field that faulted of the 99 fields of `mailing.mailing` (this instance, with `mass_mailing_sale` and `mass_mailing_crm`), each read on its own for the new mailing and for the latest 20; the fix is the per-row read of `Odoo::Ops::Mailing::Common::search_read_named` (docs/specs/mailing-5.md); the other candidates (a counter, a record rule on `mailing.mailing`) did not fault | not probed | not probed | not probed | â |
| what a user with only the mass-mailing group (`mass_mailing.group_mass_mailing_user`, `base.group_user` implied) can read | `search_read` answers on `mailing.mailing`, `mailing.list`, `mailing.contact`, `mailing.trace`, `mail.blacklist`, `link.tracker`, `mailing.mailing.test` and `ir.mail_server` (access rows of mass_mailing's `ir.model.access.csv`: read on `ir.mail_server`); it is refused on `ir.model.data` (Administration/Access Rights), `ir.cron`, `ir.cron.trigger`, `ir.config_parameter` and `mail.mail` (Administration/Settings), and on `account.move`. The same user can create a draft's test (`mailing.mailing.test`) and queue a mailing (`action_put_in_queue`): `oom-mailshot test`, `send` (queued), `watch`, `status` and `open-check` ran as that user. Live 2026-10-16 (t/85 and t/83 operator blocks, demo16; the user made through `core.user` under the stamp, deleted with its partner at the end) | not probed | not probed | not probed | - |
| the cron lookup of `mailing.status` and `mailing.process` | the two cron records are found through `ir.model.data` (`mass_mailing.ir_cron_mass_mailing_queue`, `mail.ir_cron_mail_scheduler_action`) and read from `ir.cron`, with `ir.cron.trigger` for the pending triggers: all three are administration models, so a mailing operator gets `AccessError` ("You are not allowed to access 'Model Data' (ir.model.data) records ... Administration/Access Rights"). `mailing.status` reports `queue_due` as null with a note; `mailing.send`'s plan note drops the next call; `mailing.process` (which also calls `ir.cron.method_direct_trigger`) is an administrator's operation. Live 2026-10-16 (t/85 operator block asserts the null and the note on the done mailing's read; the refusal of each model above) | not probed | not probed | not probed | - |
| `mail.mail` rows for a mailing | readable only with Administration/Settings (`You are not allowed to access 'Outgoing Mails' (mail.mail) records ... Administration/Settings`): `mailing.status queue=1` reports `queue` as null with a note and `mailing.preview`'s `tracking` cannot tell whether the delivered mail still exists. The trace's `mail_mail_id` is readable through `mailing.trace`. Live 2026-10-16 (the first run of the t/85 operator block faulted exactly there; fixed and passing) | not probed | not probed | not probed | - |
| non-ASCII text through `oom-ops` JSON | a mailing body's `&middot;` and `&nbsp;` arrive as U+00B7 and U+00A0 in the rendered HTML; `ordered_json` printed them through a `JSON::PP` with no `utf8` layer, so a character below 256 left as a lone Latin-1 byte (a `�` to a UTF-8 reader) and one above gave `Wide character in print`. Not an Odoo fact: the printer's. Fixed offline (t/44 round-trips a tab, a form feed, a middle dot, an e acute, an em dash and an astral character) and live (t/85: `oom-ops run mailing.preview --json` as the operator decodes strictly) 2026-10-16 | not probed | not probed | not probed | - |
| what Odoo answers for an empty field of each type | `false` for a char, text, html, date, datetime, selection, binary and many2one with no value; the transports decode it as `0`, which OOM turns into `null` by the field's `fields_get` type. A string `"0"` written to a char reads back `"0"`, and writing `null` or `false` clears it. Live 2026-10-16 (t/54-empty-values-live.t, 41/41): `res.partner` `function`, `phone`, `comment` (html), `date` and `parent_id` read `null` when empty, `"0"` reads `"0"`, and a revert of a write over the empty fields reads them `null` again | not probed | the same on `res.partner` (`function`, `phone`, `comment`, `parent_id`; 36/36) and on `hr.employee` `mobile_phone`, `departure_description` (html), `birthday` (date) on hr18 (59/59), live 2026-10-16 | not probed | - |
| `res.partner` has a `date` field | yes on 16 (a date field with no value reads `false`), live 2026-10-16 (t/54) | not probed | no: `core.read fields=date` is refused `res.partner has no field 'date'`, live 2026-10-16 (hr18) | not probed | - |
| a required field and its default (`default_get`) | not probed | not probed | `hr.employee`: required with a default `company_id`, `distance_home_work_unit`, `employee_type`, `marital`; required with none `resource_id` (`name` is computed there and not offered by the skeleton). Live 2026-10-16 (hr18, t/54) | not probed | - |
| two `hr.skill.level` records with one name | not probed | not probed | `Expert` is the name of ids 11 and 15, `Advanced` of 10 and 14 (one per skill type). Live 2026-10-16 (hr18, t/54): `core.import` with `lookup {"skill_level_id":"name"}` holds the row `ambiguous` naming both ids; `lookup {"skill_level_id":"id"}` is not held | not probed | - |
| `hr.attendance` as a keyed record | not probed | not probed | `check_in` reads back as `YYYY-MM-DD HH:MM:SS`, the form written; a re-run of `core.import key=employee_id,check_in` is all `unchanged`, also when the row writes a `T` separator. A create and its revert (delete) leave nothing. Live 2026-10-16 (hr18, t/54) | not probed | - |
| deleting a new `hr.employee` | not probed | not probed | the revert of a create run deletes the employee when nothing points at it (no leave, no user). Odoo made a work contact `res.partner` named as the employee, which stays; the test removes it. Live 2026-10-16 (hr18, t/54) | not probed | - |
| `hr.leave` actions and wizard (`behaviours/hr.leave/18.yaml`, `hr_holidays`) | not probed | not probed | live 2026-10-16 (t/97-hr-actions-live.t on hr18): `action_approve` confirm -> validate (the meeting and the first approver are set; a second approve is refused "must be confirmed", in Odoo's words), `action_refuse` validate -> refuse, `action_reset_confirm` refuse -> confirm; `action_cancel` answers with the `hr.holidays.cancel.leave` window and changes nothing; the wizard's `action_cancel_leave` is refused "This time off cannot be cancelled" for a leave whose employee is not the acting user (`can_cancel`); `action_validate` source only. Odoo deletes a leave from confirm or cancel only (source; a revert of an approved leave plans the delete and notes the state) | not probed | - |
| `hr.leave.allocation` actions (`hr_holidays`) | not probed | not probed | live 2026-10-16 (t/97-hr-actions-live.t on hr18): `action_approve` confirm -> validate, `action_refuse` validate -> refuse (the revert), `action_set_to_confirm` refuse -> confirm; `action_validate` source only. Odoo deletes an allocation from confirm or refuse only (source) | not probed | - |
| `hr.expense` `action_submit_expenses` (`hr_expense`) | not probed | not probed | live 2026-10-16 (t/97-hr-actions-live.t on hr18): draft -> reported; answers with a window on the new `hr.expense.sheet` | not probed | - |
| `hr.expense.sheet` actions and wizards (`hr_expense`; `approval_state` is what the actions write, `state` is computed from it) | not probed | not probed | live 2026-10-16 (t/97-hr-actions-live.t on hr18): `action_submit_sheet` (approval_state none -> submit, state draft -> submit), `action_approve_expense_sheets` (-> approve), `action_sheet_move_post` (approve -> post: Odoo makes and posts a vendor bill for the employee's contact), `action_reset_expense_sheets` (post -> draft: Odoo posts a reversal and keeps the bill and the reversal, with their numbers), `action_refuse_expense_sheets` answers with the `hr.expense.refuse.wizard` window and the wizard's `action_refuse` makes approval_state cancel; the duplicate wizard and `hr_expense_cancel`'s `action_cancel` are source only (on a server without `hr_expense_cancel`, `action_cancel` is refused `not-applicable`) | not probed | - |
| `hr.applicant` and `hr.candidate` actions and the refuse wizard (`hr_recruitment`) | not probed | not probed | live 2026-10-16 (t/97-hr-actions-live.t on hr18): `create_employee_from_applicant` makes an employee (the application stays `ongoing`) and answers with a window on it; `archive_applicant` answers with the `applicant.get.refuse.reason` window; the wizard's `action_refuse_reason_apply` refuses send_mail with no template ("Email template must be selected to send a mail") and, with send_mail false, writes the reason and archives the application; `reset_applicant` and `create_employee_from_candidate` source only. A refused application is archived (active false). A read of `id` alone answers for an id that was deleted, so a record is told gone by reading `display_name` | not probed | - |
| `hr.appraisal` actions (`hr_appraisal_oca`) | not probed | not probed | live 2026-10-16 (t/97-hr-actions-live.t on hr18): `action_confirm` 1_new -> 2_pending (the employee had no work email and no managers, so no mail), `action_back` 2_pending -> 1_new (the revert); `action_done` and the request wizard (`send_button`) source only; the mails need a work email on the employee or a manager | not probed | - |
| `hr_timesheet.sheet` actions (`hr_timesheet_sheet`) | not probed | not probed | live 2026-10-16 (t/97-hr-actions-live.t on hr18): `action_timesheet_confirm` draft -> confirm, `action_timesheet_done` confirm -> done, `action_timesheet_draft` done -> draft (the revert); the employee needs a linked user; `action_timesheet_refuse` source only | not probed | - |
| `hr.payslip` actions and `hr.payslip.run` (`payroll`) | not probed | not probed | live 2026-10-16 (t/97-hr-actions-live.t on hr18): `compute_sheet` draft -> verify (Odoo takes a number from the `salary.slip` sequence and makes the lines: 6 on the salaried structure), `action_payslip_cancel` from verify -> cancel, `action_payslip_draft` cancel -> draft and done -> draft, `action_payslip_done` verify -> done; `action_payslip_cancel` of a done payslip is refused "Cannot cancel a payslip that is done"; the run's `close_payslip_run` and `draft_payslip_run`; the `hr.payslip.employees` wizard (active_id the run) makes one payslip for the employee; `refund_sheet` and the `hr.payslip.change.state` wizard source only. Odoo deletes a payslip from draft or cancel only (source) | not probed | - |
| `hr.contract` state (`hr_contract`) | not probed | not probed | source 18.0: no action button; the state is a status bar, so `behaviours/hr.contract/18.yaml` says `written_by: write` and `core.import` does not hold it | not probed | - |
| `hr.attendance` `action_approve_overtime` and `action_refuse_overtime` (`hr_attendance`) | not probed | not probed | source 18.0: each writes `overtime_status`, a plain field (`written_by: write`); not run | not probed | - |
| `hr.employee` departure wizard (`hr`) | not probed | not probed | source 18.0 (`hr.departure.wizard.action_register_departure`); not run here. The survey met the effect of the departure date on hr18: Odoo added an inactive `hr.attendance` record (survey hr18-survey-2026-10-16, row 8) | not probed | - |
| `hr.work.entry` `action_validate` (`hr_work_entry`), `hr.course.schedule` state methods (`hr_course`, OCA), `hr.shift.planning` methods and `shift.planning.wizard` (`hr_shift`, OCA), `document.page.history` methods (`document_page_approval`, OCA), `gamification.challenge` methods, the badge grant wizard, `slide.channel` and `slide.channel.invite`, `survey.survey` and `survey.invite` | not probed | not probed | source 18.0 and the OCA trees only; each in its `behaviours/<model>/18.yaml` with the source line; not run on hr18 | not probed | - |
| a profile field, model or pack whose module is not installed (`module:` in the profile; `product_expiry` for `stock.lot.expiration_date`, `mass_mailing` for the mailing pack) | live 2026-10-16 (t/56-modules-live.t on the local 16, which has `mass_mailing` and `product_expiry`): `doctor` has no not-applicable line for the mailing pack or `lot.expiration`, and `mailing.lists` answers | not probed | live 2026-10-16 (t/56-modules-live.t on the local 18, which has `product_expiry` and no `mass_mailing`: `profile.mailing` is `info` `not applicable here: module mass_mailing is not installed`, `mailing.lists` is refused `not-applicable` naming `mass_mailing`; and on hr18, which lacks `product_expiry`, `mass_mailing` and `fleet` as well: `doctor` has no `fail`, `lot.expiration` is `info` `not applicable here, module product_expiry is not installed`) | not probed | - |
| a model of an absent module, through `core.read` (`fleet.vehicle`, no `fleet` module) | live 2026-10-16 (t/56-modules-live.t on the local 16): refused `not-applicable` naming `fleet` | not probed | live 2026-10-16 (t/56-modules-live.t on the local 18 and on hr18): over JSON-RPC Odoo answers `fields_get` of a model it does not have with a 404 `werkzeug.exceptions.NotFound`, which is no access fault; OOM refuses it `not-applicable` naming `fleet` | not probed | - |
| a method that returns a boolean, through `core.action` | not probed | not probed | the JSON transports read a server boolean as 1 or 0, so `Odoo answered with true` is what a result of 1 is reported as; live 2026-10-16 (t/97-hr-actions-live.t on hr18, a password session): `action_approve` and `compute_sheet` return true, `action_submit_sheet` returns nothing | not probed | - |
| records `hr.expense` `action_submit_expenses` makes (the `creates:` of `behaviours/hr.expense/18.yaml`) | not probed | not probed | one `hr.expense.sheet` per payer, in draft, named by `hr.expense.sheet_id`; `create_uid` is the acting user. Source 18.0 hr_expense `_create_sheets_from_expense`. Live 2026-10-17 (t/97-hr-actions-live.t on hr18, and the plain 18 block of the same file): `made: hr.expense.sheet 20 (EX0020, draft)` | not probed | - |
| records `hr.expense.sheet` `action_approve_expense_sheets` makes | not probed | not probed | core 18.0 `_do_approve` calls `_do_create_moves`, which makes the vendor bill of an own-account report in draft with `sudo()` (the move's `create_uid` stays the acting user: `sudo()` keeps the uid) and, for a company-paid report, an `account.payment` and its move. Live 2026-10-17 on the plain 18 (t/97-hr-actions-live.t): one draft `account.move` named by `account_move_ids` (a one2many on 18), deleted by `action_reset_expense_sheets`. On hr18 none is made at approve: the OCA `hr_expense_invoice` (installed there) bypasses `_do_create_moves` for an own-account report, so the move is made at post (live 2026-10-17: the approve reports nothing). The company-paid case is not probed: the plain 18 refused the approve for want of a payment method, so `account.payment` is not listed | not probed | - |
| records `hr.expense.sheet` `action_sheet_move_post` makes | not probed | not probed | `account.move` through `_do_create_moves` when the report has none, named by `account_move_ids`. Source 18.0 hr_expense. Live 2026-10-16 (the 0.24 run of t/97-hr-actions-live.t with `ODOO_OOM_LIVE_POSTS=1` on hr18: a vendor bill made and posted). Not re-run on 2026-10-17: posting stays behind `ODOO_OOM_LIVE_POSTS` | not probed | - |
| records `hr.applicant` `create_employee_from_applicant` and `hr.candidate` `create_employee_from_candidate` make | not probed | not probed | an `hr.employee`, named by `employee_id` on the applicant and on the candidate, and a `res.partner` for the candidate when it has no contact (`partner_id`). Source 18.0 hr_recruitment hr_candidate. Live 2026-10-17 (hr18): the applicant hire of a candidate with a contact made the employee only; the candidate hire with its contact taken off made the employee and the contact. Odoo also makes the employee's `resource.resource`, `hr.resume.line` and, with the OCA hr_employee_calendar_planning, a `resource.calendar`; the file does not list them | not probed | - |
| records `hr.leave` `action_approve` makes (the last approval) | not probed | not probed | `resource.calendar.leaves` (sudo, so the acting user), an `account.analytic.line` (project_timesheet_holidays) and a `calendar.event` named by `meeting_id` that Odoo makes `with_user` the employee's user, so its `create_uid` is the employee's login (32 against the acting user 2) and the search does not find it: it is reported linked, not made in this call. Source 18.0 hr_holidays `_validate_leave_request`. Live 2026-10-17 (hr18) | not probed | - |
| records `hr.payslip` `compute_sheet`, `action_payslip_done` and the `hr.payslip.employees` wizard make | not probed | not probed | `compute_sheet` deletes the lines and writes new `hr.payslip.line` rows (6 on the demo contract); `action_payslip_done` computes first, so it makes them again; the wizard makes the `hr.payslip` (named by the batch's `slip_ids`), its lines and an `hr.payslip.worked_days` row. Source OCA payroll hr_payslip, hr_payroll_payslips_by_employees. Live 2026-10-17 (hr18) | not probed | - |
| `hr.contract` state is moved by a write, not by a public method | not probed | not probed | Source 18.0 hr_contract `hr_contract.py`: `state` is changed by the status bar and by the cron `update_state` (a model method with no record); the public methods are `action_open_*` windows. live 2026-10-17 (t/60-hr-coverage-live.t, hr18): `core.import` wrote `open` -> `close` -> `open` with no `state-field` hold (the file says `written_by: write`); the write of `close` gave a contract with no end date the end date 2031-01-01, its start date | not probed | - |
| records `hr.contract` `action_update_overtime` (OCA `hr_contract_update_overtime`) and the renew wizard (`hr_contract_renew`) change or make | not probed | not probed | `action_update_overtime` writes nothing on the contract and posts "Overtime updated" (a contract not `open` or `close` is skipped without a word). The wizard `hr.contract.renew.wizard` `action_renew_contract` copies the contract into a draft `hr.contract` starting on `date_end` (named in the result) and sets the old end date to the day before; the copy keeps the old end date, so Odoo refuses `start date (2032-01-01) must be earlier than contract end date (2031-01-01)` when that is earlier. Source OCA; live 2026-10-17 (t/60-hr-coverage-live.t, hr18) | not probed | - |
| 18 has `calendar.public.holiday`, not `hr.holidays.public` | not probed | not probed | `hr_holidays_public` depends on `calendar_public_holiday`: a year and a country with dated lines, no state, no validate method. The wizard `calendar.public.holiday.next.year` `create_public_holidays` makes the next year, a copy of each line and a `calendar.event` per line (five records in live 2026-10-17 (t/60-hr-coverage-live.t, hr18)); it refuses a template with a line on 29 February and a year that exists. A year's lines must be deleted through the ORM before the year, or their events stay. Source OCA calendar_public_holiday | not probed | - |
| `resource.booking` (OCA `resource_booking`) state is computed; four public methods | not probed | not probed | `state` is `pending`, `scheduled`, `confirmed` or `canceled`, computed from the archive flag and the meeting's attendee; a write of `start` schedules the booking, `action_confirm` accepts the requester (scheduled -> confirmed), `action_unschedule` deletes the meeting (-> pending), `action_cancel` archives the booking (-> canceled), `action_schedule` answers with a calendar window. The working hours are the type's calendar in its time zone (15:00 UTC was inside America/New_York hours, 10:00 UTC was refused: no resources are selected). Source OCA resource_booking; live 2026-10-17 (t/60-hr-coverage-live.t, hr18) | not probed | - |
| timers: `project_timesheet_time_control` on `project.task` and `account.analytic.line` | not probed | not probed | `button_start_work` and `button_resume_work` answer with a window on `hr.timesheet.switch`; the wizard's `action_switch` makes the running line (`create` or a copy; named in the result). `button_end_work` writes the hours (the context `stop_dt` ends the timer at that time); on a line with hours it is refused (`Cannot stop timer N because it is not running`), on a task with none running too (`No running timer found in Task X`). On hr18 the acting user's employee has two placeholder timers, so the wizard is refused (`2 running timers found`) unless `running_timer_id` is given as false; with no line to copy `hr_timesheet_time_control_begin_end` makes Odoo answer `unsupported operand type(s) for +: 'dict_keys' and 'list'`. Source OCA; live 2026-10-17 (t/60-hr-coverage-live.t, hr18) | not probed | - |
| records `account.analytic.line` `action_autodraft_timesheet_sheets` (OCA `hr_timesheet_sheet_autodraft`) makes | not probed | not probed | One draft `hr_timesheet.sheet` for lines on no sheet (named by `sheet_id`; Week 15, 2031 for two lines of 2031-04-08 and 09), only when the company setting `timesheet_sheets_autodraft` is on; with it off nothing is made. Source OCA; live 2026-10-17 (t/60-hr-coverage-live.t, hr18) | not probed | - |
| a company-related settings field is left out of `res.config.settings.default_get` | not probed | not probed | `timesheet_sheets_autodraft` (related to the company) is absent from `default_get` when the company has it on, so `core.configure` planned `false` as `unchanged`. A new unsaved settings record (`onchange` with `company_id` in the spec) computes it from the company; `core.configure` reads a field `default_get` left out that way. live 2026-10-17 (t/60-hr-coverage-live.t, hr18) | not probed | - |
| attendance check in and out: OCA `hr_attendance_rfid` `register_attendance(card_code)` is `@api.model`, listed `on: model` | not probed | not probed | Core `hr_attendance` changes an attendance only through the private `_attendance_action_change` (HTTP routes call it). `register_attendance` is defined on `hr.employee.base` with `@api.model`: called with the ids first it answers `takes 2 positional arguments but 3 were given`; `core.action` with `args=[card code]` and no record checked a stamped employee in (`check_in`, one `hr.attendance` made and named) and, the second call, out (`check_out`, none made, written). A card no employee holds is answered with `logged` false and `error_message`, not refused. Source OCA hr-attendance `hr_attendance_rfid` `models/hr_employee.py`; live 2026-10-17 (t/60-hr-coverage-live.t, hr18) | not probed | - |
| `dms.field.template` `create_dms_directory` is `@api.model` with no arguments, listed `on: model` | not probed | not probed | Reads `res_model` and `res_id` from the context and makes the record's directory from the template (`dms.directory`, named by the `made:` line; Odoo answers the recordset as `dms.directory(40,)`); with `install_mode` the template made its own root directory first, and without one Odoo refused `A root directory has to have a storage.`. A second call for the same record is refused `There is already a linked directory created.`. Source OCA dms `dms_field/models/dms_field_template.py`; live 2026-10-17 (t/60-hr-coverage-live.t, hr18) | not probed | - |
| `hr.shift.planning` has no name; key `year,week_number` | not probed | not probed | Unique on `(year, week_number)`; `core.import` made one and a second run was `unchanged`. `generate_shifts` made one `hr.shift.planning.shift` per employee marked `shift_planning` (nine) and moved it to `assignment`; a shift has no name (Odoo names it `hr.shift.planning.shift,N`). Source OCA hr_shift; live 2026-10-17 (t/60-hr-coverage-live.t, hr18) | not probed | - |
| `hr.resume.line`, `hr.candidate.skill`, a job's `survey_id` import | not probed | not probed | `hr.resume.line` key `employee_id,name`; `hr.candidate.skill` key `candidate_id,skill_id` (candidate by `partner_name`, skill, level and type by `id`); `hr.job.survey_id` by the survey's `title`. Each second run `unchanged`. `hr.applicant` `action_print_survey` answers with an `ir.actions.act_url`, `action_send_survey` with a window on `survey.invite` (refused for a survey with no questions: `You cannot send an invitation for a survey that has no questions.`). Source 18.0 hr_skills, hr_recruitment_skills, hr_recruitment_survey; live 2026-10-17 (t/60-hr-coverage-live.t, hr18) | not probed | - |
| `hr.leave.type` settings, `hr.leave.accrual.plan` and `.level`, an accrual allocation import | not probed | not probed | Imported by name (selections by value); an allocation with `allocation_type` `accrual` and `accrual_plan_id` was made and approved (`confirm` -> `validate`) by `core.action`. `hr_holidays_settings` adds only a settings view. Source 18.0 hr_holidays, OCA hr_holidays_settings; live 2026-10-17 (t/60-hr-coverage-live.t, hr18) | not probed | - |
| `dms.file` and an employee's documents load through the existing primitives | not probed | not probed | `core.import` made a `dms.file` with `content` as base64 (key `directory_id,name`; it reads back as written); `core.attach` put a file on an `hr.employee` (`document_count` of `hr_employee_document` reads 1; the revert is held `irreversible`). With `hr_dms_field`, a `dms.field.template` for `hr.employee` created with `install_mode` in the context gives a new employee a directory in the template's storage; the directory is visible to the acting user only through a `dms.access.group` the template names, and deleting the template removes the directories. Source OCA dms, dms_field, hr_dms_field, hr_employee_document; live 2026-10-17 (t/60-hr-coverage-live.t, hr18) | not probed | - |
| `hr.expense` `action_expense_create_invoice` (OCA hr_expense_invoice) | not probed | not probed | makes one draft `in_invoice` `account.move` (price the expense's untaxed amount), named by `invoice_id`, `create_uid` the acting user. For an expense in no report Odoo refuses `Vendor bill state must be Posted`, because the expense's `_check_invoice_id` constraint wants a posted bill when there is no report. Source OCA hr_expense_invoice hr_expense. Live 2026-10-17 (hr18, t/59-hr-expense-flow-live.t) | not probed | - |
| a report whose expenses carry a posted vendor bill, posted (OCA hr_expense_invoice) | not probed | not probed | `action_sheet_move_post` makes a posted transfer entry in the general journal (`MISC/...`, named by `account_move_ids`) and the report reads `post`; `action_cancel` then deletes the entry, cancels the bill and sets the report to `submit`. Source OCA hr_expense_invoice hr_expense_sheet. Live 2026-10-17 (hr18, t/59 with `ODOO_OOM_LIVE_POSTS=1`) | not probed | - |
| `hr.expense.sheet` `action_register_payment` and the `account.payment.register` wizard (OCA hr_expense_payment) | not probed | not probed | the method answers with the wizard's window and changes nothing; the window's context is `active_model` `account.move`, `active_ids` the report's `account_move_ids` and `expense_sheet_ids`. `action_create_payments` with that context (the caller passes it to `core.wizard`) makes one `account.payment` (named by `payment_ids`) and its posted `account.move`, and the report goes `post` -> `done`, `payment_state` `paid`. Source 18.0 account account_payment_register, OCA hr_expense_payment. Live 2026-10-17 (hr18, t/59 with `ODOO_OOM_LIVE_POSTS=1`) | not probed | - |
| `hr.expense.sheet` `action_cancel` (OCA hr_expense_cancel) on a paid report | not probed | not probed | `state` `done` -> `submit` (`approval_state` stays `approve`): the bill is deleted, the payment is cancelled and stays in `payment_ids`, `payment_state` goes `paid` -> `not_paid`. On an approved report with no entry only `state` moves. Source OCA hr_expense_cancel hr_expense. Live 2026-10-17 (hr18, t/59) | not probed | - |
| `hr.expense.sheet` `set_to_paid` and `set_to_posted` | not probed | not probed | public hooks that write `state` (`done`, `post`) directly, for other modules to bypass the payment and the move; not listed, so `core.action` refuses them `unlisted-action`. Likewise the methods that only open a screen (`action_open_account_moves`, `action_view_invoices`, `open_clear_advance`, `action_popup_exceptions`). Source 18.0 hr_expense hr_expense_sheet, OCA hr_expense_invoice, hr_expense_advance_clearing, base_exception. Live 2026-10-17 (hr18, t/59: refused `unlisted-action`) | not probed | - |
| a report paid from petty cash (OCA hr_expense_petty_cash) | not probed | not probed | `petty.cash` has no method that changes state. `action_approve_expense_sheets` makes and posts the entry (`account.move`, named by `account_move_ids`) and the report reads `post`; `action_sheet_move_post` after it is refused `The entry ... must be in draft.`; a report for more than the holder's balance is refused when the report is made, `Not enough money in petty cash holder.`. Source OCA hr_expense_petty_cash hr_expense_sheet. Live 2026-10-17 (hr18, t/59 with `ODOO_OOM_LIVE_POSTS=1`) | not probed | - |
| a company-paid report (`payment_mode` `company_account`) | not probed | not probed | the approve and the post are refused `A default outstanding account must be defined in the settings for company-paid expenses.` (hr18 has no outstanding account on the Manual Payment (Bank) method); what the post makes for such a report is source only. Live 2026-10-17 (hr18, t/59 with `ODOO_OOM_LIVE_POSTS=1`) | not probed | - |
| an advance (OCA hr_expense_advance_clearing) | not probed | not probed | no method of its own that changes state: an advance and its clearing are reports posted by `action_sheet_move_post`. The `Employee Advance` product has no expense account on hr18 and an advance expense is refused `Employee advance product has no payable account`, so the post and the clearing are source only. Source OCA hr_expense_advance_clearing. Live 2026-10-17 (hr18, t/59: the refusal) | not probed | - |
| an exception rule that fails a report (OCA base_exception, hr_expense_exception) | not probed | not probed | `action_submit_sheet` and `detect_exceptions` fail with `{"src_model": "hr.expense.sheet", "target_model": "hr.expense.sheet"}` and the rule is stored on the report (`exception_ids`) in a transaction of its own; `action_ignore_exceptions` then `action_submit_sheet` submits. The wizard `expense.sheet.exception.confirm` `action_confirm` with `ignore` resets the report, ignores and submits again, and Odoo raises the exception again inside the call: refused, nothing changed. Source OCA base_exception base_exception_method, hr_expense_exception. Live 2026-10-17 (hr18, t/59) | not probed | - |
| making an `exception.rule` and a `petty.cash` | not probed | not probed | the hr18 ops login reads both and may not make either: `exception.rule` wants the group Exception manager (`base_exception.group_exception_rule_manager`), `petty.cash` the accounting group (`account.group_account_user`). The test makes a user under its stamp with those groups, as `t/lib/Odoo/Test/GroupOperator.pm`, and removes it. Live 2026-10-17 (hr18, t/59) | not probed | - |
| tier validation of a report (OCA base_tier_validation, hr_expense_tier_validation) | not probed | not probed | `request_validation` makes one `tier.review` per definition that applies (named by `review_ids`, status `pending`), `validation_status` `no` -> `pending`; `action_approve_expense_sheets` is refused `A validation process is still open for at least one record.`; `validate_tier` -> `validated` and the approve then applies; `reject_tier` -> `rejected`; `restart_validation` deletes the reviews (-> `no`). A definition with `has_comment` makes `validate_tier` answer with the `comment.wizard` window, and `add_comment` (values `res_model`, `res_id`, `review_ids`, `validate_reject`, `comment`) validates. `action_reset_expense_sheets` of a submitted report whose validation is done is refused `You are not allowed to write those fields under validation.` until `restart_validation`. Source OCA base_tier_validation tier_validation, comment_wizard. Live 2026-10-17 (hr18, t/59) | not probed | - |
| `tier.review` | not probed | not probed | no public method changes its state; `status` is written by the methods of the validated record, so `core.import` holds a row that sets it `state-field`. Source OCA base_tier_validation tier_review. Live 2026-10-17 (hr18, t/59) | not probed | - |
| `hr.payslip` confirmed and cancelled with OCA payroll_account | not probed | not probed | with accounts on the salary rules, `action_payslip_done` makes one posted `account.move` in the contract's journal, named by `move_id`; with none (the demo rules) it makes none. `action_payslip_draft` keeps the entry; `action_payslip_cancel` of that draft payslip deletes it (`move_id` null); `action_payslip_cancel` of a done payslip is refused `Cannot cancel a payslip that is done.` and the entry stays (the refusal rolls the removal back). `refund_sheet` makes the credit note (`refunded_id`), its lines and its own posted entry, and the original cannot be cancelled until the credit note is. Source OCA payroll_account hr_payslip, payroll hr_payslip. Live 2026-10-17 (hr18, t/59 with `ODOO_OOM_LIVE_POSTS=1`) | not probed | - |
| `payroll.management.wizard` `send_payrolls` (OCA hr_payroll_document) | not probed | not probed | answers with a `display_notification` client action. It makes two `ir.attachment` payroll PDFs (the second is the mail template's), one `ir.attachment.payroll.custom` and one `mail.mail`, which reads state `exception` with `-2 Name or service not known` on hr18 (no mail server); the employee's avatar images are stored the first time they are read, and are named among what was made. The employee needs an `identification_id` that is in the PDF's text, and the company a country. The wizard sets `attachment_ids` on the shared mail template and writes the PDF under `/tmp` of the Odoo server. Source OCA hr_payroll_document payroll_management_wizard. Live 2026-10-17 (hr18, t/59) | not probed | - |
| a read of `display_name` for an id that is not there | not probed | not probed | answers `<model>,<id>` for a transient model's deleted record instead of a missing-record fault; a `search` on the id is what shows a record gone. A transient `account.payment.register` row keeps its partner from being deleted until Odoo's vacuum removes it, and the ops login may not delete it. Live 2026-10-17 (hr18, t/59) | not probed | - |
| Odoo's two-factor step (`auth_totp`) after a right password at `/web/session/authenticate` | live 2026-10-17 (`t/62-session-totp-live.t`): the answer is `{uid: null}` with a `session_id` cookie; `GET /web/login/totp` serves the form (`csrf_token`, `redirect`, `totp_token`, `remember`); a POST of `csrf_token`, `totp_token` answers 303 and sets a new `session_id`; a wrong code answers 200 with the form and `Verification failed, please double-check the 6-digit code`; `remember=1` sets the cookie `td_id` (Max-Age 90 days) and a POST with it needs a `User-Agent` Odoo can place (a bare agent is HTTP 500 at `user_agent.browser.capitalize()`); a later sign-in sends `td_id` and Odoo reads it at the `GET` of the form (303, no code), and `revoke_all_devices` makes it unknown again | not probed | live 2026-10-17: the same route, fields, words and cookie (also hr18) | live 2026-10-17: the same route, fields, words and cookie | - |
| API key of an archived user (keys-1 fact 1) | REFUSED, live 2026-10-17 (`t/62-keys-live.t`): the login call answers false (`authentication failed ... Odoo answered false and gave no reason`, category `credential`); a client already signed in is answered `Odoo Server Error: Access Denied` on its next call, on 12 calls in a row; source: `u.active` in the key check | not probed (same source) | REFUSED, live 2026-10-17, as 16, on the local 18 and on hr18 | REFUSED, live 2026-10-17, as 16 | - |
| API key of a user active again (fact 2) | the same key works again, no new key, live 2026-10-17 | not probed | same, live 2026-10-17 (local 18, hr18) | same, live 2026-10-17 | - |
| API key of a user whose groups are removed (fact 3) | still authenticates (same uid); `res.partner` read refused as access: `You are not allowed to access 'Contact' (res.partner) records.`; the user's own `res.users.apikeys` rows are refused as well; live 2026-10-17 | not probed | same, live 2026-10-17 (local 18, hr18) | same, live 2026-10-17 | - |
| API key of a user with Odoo two-factor on (fact 4) | works for RPC (uid, reads); the same user's password opens no web session (`second_factor`); live 2026-10-17 | not probed | same, live 2026-10-17 (local 18, hr18) | same, live 2026-10-17 | - |
| key expiry: the column, the answer, the clean-up (fact 5) | no `expiration_date` on `res.users.apikeys`: a key never expires (live 2026-10-17: the field is absent; source) | none in the source; not probed | `expiration_date` present; the wizard's one day is the next UTC midnight (`2026-10-18 00:00:00` for a key made 2026-10-17); an expired key is refused as in fact 1, with no word of the date (live 2026-10-17, a key made already past by a system user); the daily cron "Base: Auto-vacuum internal data" (`lastcall`/`nextcall` read) runs `_gc_user_apikeys` (source); live: no key that expired before the cron's last call was left; on hr18 the cron triggered by `ir.cron.method_direct_trigger` (no other expired key present) deleted the expired key; on the local 18 it was not triggered (other expired keys would have gone with it) | as 18 (live 2026-10-17; the same cron and `_gc_user_apikeys`; no key that expired before the cron's last call was left; the cron was not triggered, other expired keys would have gone with it) | - |
| a key deleted by an administrator (fact 6a) | `unlink` over RPC refused (access) for everyone; `res.users.apikeys.remove` over a web session with the identity check works. A new sign-in is refused at once. A client already signed in is answered by any worker that checked the key before, until Odoo's caches clear (source: `remove` clears no cache): of eight trials five were answered on six calls in a row, three on some; one key answered ten of ten at 20 s and none at 40 s; archiving the user clears them; live 2026-10-17 | not probed (same source) | the same, live 2026-10-17: of six trials four answered on all six calls, two on five; twelve calls right after: twelve answered (local 18, hr18) | refused at once for every call, new or signed in: `remove` clears the registry cache (source); six of six trials, twelve of twelve calls, live 2026-10-17 | - |
| a key deleted by the user (fact 6b) | the same as 6a, through `remove` as the user over a web session; live 2026-10-17 | not probed | the same, live 2026-10-17 | the same as 6a, live 2026-10-17 | - |
| a session already open by password when a key is deleted (fact 6c) | not affected: it goes on answering, live 2026-10-17 | not probed | same, live 2026-10-17 | same, live 2026-10-17 | - |
| what a user reads of their own keys; what an administrator reads of others' (fact 7) | `name`, `scope`, `create_date`, `user_id`; no field holds the key; a user sees only their own rows (record rule); an administrator sees every row; a user with no group may not read the table; live 2026-10-17 | not probed | the same and `expiration_date`, live 2026-10-17 (local 18, hr18) | the same as 18, live 2026-10-17 | - |
| `core.whoami` reports `credential` and the login's own keys, no value (keys-1) | live 2026-10-17 (`t/62-keys-live.t`): one key row by name, scope, creation date; `keys_readable` 0 for a user with no group | not probed | live 2026-10-17 (local 18, hr18), with `expiration_date` | live 2026-10-17, with `expiration_date` | - |
| timers on `project.project` (OCA `project_timesheet_time_control`) | not probed | not probed | The project has the mixin's `button_start_work` and `button_end_work`; `button_resume_work` is defined on `account.analytic.line` only. `button_start_work` answers with a window on `hr.timesheet.switch` whose context asks for no task. The wizard `action_switch` run for the project, with a line of the project to copy and `running_timer_id` false, made one running line on the project with no task (`create_uid` the acting user); `button_end_work` with `stop_dt` in the context gave it 2.5 hours between 09:00 and 11:30, and with none running Odoo refused `No running timer found in Project X. Refresh the page and check again.` Source OCA `project_timesheet_time_control` `models/project_project.py`, `hr_timesheet_time_control_mixin.py`; live 2026-10-17 (t/60-hr-coverage-live.t, hr18) | not probed | - |
| `hr.expense` `action_approve_duplicates` | not probed | not probed | Posts one `mail.message` on each expense of `duplicate_expense_ids` (same employee, product, date, amount, currency and company; the expense itself is in it), author OdooBot, `create_uid` the acting user, body `<user> confirms this expense is not a duplicate with similar expense.`; no state or field changes. Source 18.0 `hr_expense/models/hr_expense.py`; live 2026-10-17 (t/59-hr-expense-flow-live.t, hr18: two similar draft expenses, two messages, state still draft) | not probed | - |
| `hr.expense` `action_split_wizard` and `hr.expense.split.wizard` `action_split_expense` | not probed | not probed | `action_split_wizard` makes the wizard and two `hr.expense.split` halves (rounded up and down) as transient records and answers with a window on the wizard; the expense is unchanged. `action_split_expense` writes the first split line onto the expense and `copy`s the expense for each further line (attachments copied too): a 30 expense split 10/20 left the expense at 10 and made one `hr.expense` of 20 (`create_uid` the acting user). A split line created without `expense_id` makes Odoo answer `Expected singleton: res.currency()`: each line carries `expense_id`, `currency_id` and `company_id`. No login may delete the wizard or its lines (`You are not allowed to delete 'Expense Split Wizard' (hr.expense.split.wizard) records.`): Odoo's vacuum removes them. Source 18.0 `hr_expense/models/hr_expense.py`, `wizard/hr_expense_split_wizard.py`, `wizard/hr_expense_split.py`; live 2026-10-17 (t/59-hr-expense-flow-live.t, hr18) | not probed | - |
| a wizard opened with no record (cleanup-1 F3) | not probed | not probed | Searched on hr18 on 2026-10-17: 123 window actions have `target` `new`, 110 of them on a transient model, 66 of those unbound to a model, and 11 are opened by a menu item with no record: `base.language.export`, `base.language.import`, `calendar.public.holiday.next.year`, `date.range.generator`, `hr.timesheet.report.wizard`, `hr.timesheet.switch` (Start work), `payroll.management.wizard`, `recompute.theoretical.attendance`, `wizard.dms.classification`, `wizard.generate.medical.examination`, `wizard.theoretical.time`. None is in stock, sale or account. `payroll.management.wizard` (OCA `hr_payroll_document`) reads no `active_ids`: its entry is `on: model` and `core.wizard` runs it with no records (t/59-hr-expense-flow-live.t, two payroll attachments, the payroll record and the mail made). The others are not listed; a wizard opened by a list button that calls a Python method (as stock's) is not in this search | not probed | - |
| deleting what an audit test made (hr_holidays) | not probed | not probed | A leave in `refuse` cannot be deleted by a time-off manager (the source allows only `cancel` and `confirm`; the earlier runs of the test left such leaves archived) until `action_reset_confirm` puts it in `confirm`; then the leave, its type, the employee, the user and the two partners (the one made at the employee's creation and the user's) are all deleted by `unlink`; live 2026-10-17 (t/58-audit-live.t, hr18: `LEFT 18: nothing`). Source 18.0 `hr_holidays/models/hr_leave.py` `_unlink_if_correct_states` | not probed | - |
| Discuss models (discuss-1 survey): channels, members, messages | live 2026-10-17 (demo16, `t/64-discuss-live.t`): `mail.channel` (`channel_type` `channel`, `chat`, `group`; `member_count`, `is_member`), `mail.channel.member` (`channel_id`, `partner_id`, `seen_message_id`, `fetched_message_id`, `message_unread_counter` computed), messages are `mail.message` with `model` `mail.channel` and `res_id` the channel; `general` (type channel) and a chat made by `channel_get` read live, `group` from source (`mail_channel.py`) | not probed | not probed (17 onward rename the models `discuss.channel` and `discuss.channel.member`; the pack refuses those series by name) | not probed (as 18) | - |
| who can read and post to a channel | live 2026-10-17: a plain internal user (only `base.group_user`) that is no member reads a `channel`-type channel's messages and posts to it; the member row decides nothing there. A chat or a group takes its members (record rule `mail_channel_rule`, source) | not probed | not probed | not probed | - |
| posting: `message_post` on the channel | public; live 2026-10-17: `message_type=comment`, `subtype_xmlid=mail.mt_comment`, `body` HTML, `partner_ids`, `attachment_ids`, `parent_id` return the new message id; the message reads `comment` with subtype Discussions. The channel's `message_post` defaults `message_type` to `notification` (source), so the pack sends `comment` as Odoo's client does. The author's own member row moves to the message (`seen` and `fetched`, unread 0) and the others' unread counters rise by one (live) | not probed | not probed | not probed | - |
| reply: `parent_id` on a channel | live 2026-10-17: the parent is kept as given, so a reply to a reply has the replied message as parent (a channel does not climb to the first ancestor, source `_message_compute_parent_id`); a parent that is a message of another channel is dropped without a word and the message is posted unthreaded; `discuss.post` holds that reply (`reply-elsewhere`) | not probed | not probed | not probed | - |
| mentions and attachments on a post | live 2026-10-17: `partner_ids` become the message's recipients and Odoo notifies each by the user's setting (an email notification, `notification_status` sent, read live); `attachment_ids` of `ir.attachment` rows made with `res_model` `mail.channel` and `res_id` the channel are linked to the message | not probed | not probed | not probed | - |
| marking a channel read: the public method and the route | live 2026-10-17: `_channel_seen` is private and Odoo refuses it over RPC ("Private methods (such as 'mail.channel._channel_seen') cannot be called remotely."); `channel_fetched` is public and moves `fetched` of a chat only. Odoo's client uses the JSON route `/mail/channel/set_last_seen_message` (`channel_id`, `last_message_id`), which the session transport reaches with its cookie (no CSRF token for a JSON route): it answers the message id and moves `seen_message_id` and `fetched_message_id` forward and recounts `message_unread_counter`. Choice: the route, over a web session as the login | not probed | not probed | not probed | - |
| the seen message moves forward only | live 2026-10-17 (`t/64-discuss-live.t`): the route asked for an earlier message answers that message's id and leaves `seen_message_id` where it was, so `discuss.seen` skips such a request and a revert of seen is held `irreversible` | not probed | not probed | not probed | - |
| a login that is no member marks a channel read | live 2026-10-17: the route answers `404: Not Found` (no member row); `discuss.seen` plans it with a note and Odoo's answer comes back on apply | not probed | not probed | not probed | - |
| deleting a channel message: the client's path and the RPC alternatives | live 2026-10-17: the 16 client empties the message at the JSON route `/mail/message/update_content` (`message_id`, `body` empty, `attachment_ids` empty), which calls the private `_message_update_content`; it answers `{id, body: "", attachments: []}`. Over RPC Odoo allows `mail.message.unlink` and `write` to any internal user who can reach the channel (a plain non-member of a public channel unlinked and edited a member's message): the record goes, with no author rule. Choice: the client's route, which keeps Odoo's author rule | not probed | not probed | not probed | - |
| who may empty a message through the route | live 2026-10-17: its author, or a user with Access Rights (`base.group_erp_manager`, Odoo's `_is_admin`, source `controllers/discuss.py`); a member who did not write it and a non-member get `404: Not Found: 404 Not Found: The requested URL was not found on the server...`. An administrator over the key config (`own_web_session`, key = password) emptied a member's message | not probed | not probed | not probed | - |
| what remains of a deleted channel message | live 2026-10-17: the `mail.message` record stays on the channel with author, date, parent and recipients; `body` reads empty, `attachment_ids` is empty and the `ir.attachment` rows are deleted; a second call is accepted and changes nothing. A message that is not a `comment` (a system notification) is refused: "Only messages type comment can have their content updated on model 'mail.channel'" (a UserError, in Odoo's words) | not probed | not probed | not probed | - |
| the web routes through OOM's transports | live 2026-10-17: `Odoo::Transport::Session->route($path, \%params)` calls a JSON controller as the session's user; a `credential = password` config has that session; a key config opens one with its login and key (`own_web_session`), which works where the key is the login's password (the local cluster) and fails for an API key (the web login refuses a key, the row above on /web/session/authenticate) | not probed | not probed | not probed | - |
| `core.make` of a `crm.lead` with a name, type, email and contact (record-1) | live 2026-10-17 (`t/65-core-one-record-live.t`): made, read back, reverted away; the CRM pack's `probability-manual` is not read for it. A lead made with no probability sits on its automated score (leads on the automated score 18 -> 19 around the create), which that rule would have failed | not probed | a plain `crm.lead` create by RPC faults on the demo18 instance (`Odoo Server Error: county_id`, no field of that name in `ir.model.fields`), so the create is not proven there; `core.set` and `core.get` of a lead are not proven there either (no lead exists) | live 2026-10-17: made, read back, reverted away (leads on the automated score 0 -> 1; also hr18 1 -> 2) | - |
| `core.make` of a `res.users` with a name | refused at plan: `res.users needs login, partner_id (required, and Odoo gives no default)`; `partner_id` is required on `fields_get` and Odoo fills it through `_inherits` | not probed | same, live 2026-10-17 | same, live 2026-10-17 | - |
| `core.set` of an html field (`res.partner.comment`) from plain text | live 2026-10-17: read back as `<p>first line</p><p>second line</p>` | not probed | same, live 2026-10-17 | same, live 2026-10-17 | - |
| the `write_date` of `ir.model.fields` rows | live 2026-10-17 (perf-1, `t/71-perf-cache-live.t`, 16, 18, 19): most rows, the ones a module loaded, have `write_date` empty (false); on 16 every row read had none, on 18 and 19 the newest dated row was from 2026-10-13. A descending order puts the empty ones first. A cache of `fields_get` is therefore checked against the newest row id, the row count and the newest non-empty `write_date`, not the date alone. Making a manual field adds a row and removing it takes one away, and both moved the state |
| a call made with a uid Odoo does not know | live 2026-10-17 (16, 18, 19): `execute_kw` with an unknown uid and a key answers a `MissingError` ("Record does not exist or has been deleted. (Record: res.users(N,), User: N)"), category `missing`, not an `AccessDenied`. The remembered-uid path meets it with one `authenticate` |
| `read_group` with no `groupby` on `ir.model.fields` | live 2026-10-17 (16, 18, 19): the row shape differs by series (16 answers `id` and a null `write_date`; 18 and 19 answer `__domain` and the date), so the field cache does not use it |
| a note posted with `message_post(body=<html string>, subtype_xmlid=mail.mt_note)` on a lead (the lab's `lab.crm.note`) | the body is kept as the tags sent: read back as the same words, live 2026-10-17 | not probed | not probed (no lead can be made on the plain demo 18) | the string is escaped: the stored body reads `&lt;p&gt;...` and shows its own tags, live 2026-10-17 | - |
| `crm-page.note` (a `mail.message` created on the lead: subtype Note, internal, `body` html), read back by `crm-page.messages`, reverted | live 2026-10-17 (`packs/crm-page/t/20-crm-page-live.t`): applied, read back as text, revert removes it | not probed | live 2026-10-17 on hr18 only (the plain demo 18 faults on any lead create, `county_id`) | live 2026-10-17: same as 16 | - |
| `fields_get` gives a field Odoo computes a non-empty `depends`; a required, stored, computed field is filled in at create | live 2026-10-18 (t/76-params-live.t, demo16): `sale.order` `partner_invoice_id`, `partner_shipping_id`, `pricelist_id` (depends `partner_id`) and `warehouse_id` (depends `user_id`, `company_id`) are `required` and not `readonly`, `default_get` gives none, and a create without them succeeds | not probed | live 2026-10-18 (demo18, hr18): the same create with two `order_line` commands succeeds | live 2026-10-18 (demo19): the same | - |

## 10. Onchange and x2many (SM747 seam)

Writes never invoke onchange (mapper decision, `docs/USAGE.md`): the
tools set only stored fields they name, and a created lead is what the
API creates, not what a form would. x2many values go through
`Odoo::Commands`; operations add tags by `(4, id)` and never replace a
set unless told to (`on_match: overwrite`).

## Open (the spec's own list)

- Live verification on the v16 CRM account (pending).
- Session transport for OA2.
- Descriptor comparison with the data extension.

# What filing the spec closed, and what it did not

| Seam this filing held open | State |
| --- | --- |
| The proxy's request-shaping layer (OB2, OB3) | **CLOSED.** Section 4: the Guard is the scoped mode and its absence is general mode, which is the division X4-b already ruled |
| Onchange and x2many (OM2's write behaviour) | **CLOSED**, section 10 - with a documentation obligation attached rather than a free choice |
| Which strategies ride on OOM | **CLOSED, and the work it found is done (2026-10-13)**: `file` and `session` ship (0.03); `cookie` refuses by design, a consumer turning it into a session first; an API key cannot start a session (sections 7 and 9) |
| Field descriptors sharing a rendering layer with the data extension | **CLOSED 2026-10-12 by ruling (R4)**: they share it. Slice R; where the type mapping lives was Q3, **answered by OOM in 0.02**: `portable_type` on the descriptor, and `rows` beside `fields` on a display read (section 8) |
| The MCP tool set (OM2) | **CLOSED 2026-10-12 by ruling (R5)**: all operations. The spec settled the vocabulary - a tool is a named operation with a declared scope; the registry lists 12 CRM, 2 Comms and 2 Core operations today, and a new pack becomes tools with no engine work. Slice E |

**The spec's own open list, carried here rather than left in another tree:**

1. live verification on the v16 CRM account (pending);
2. the session transport for OA2 - **still listed in the source's own Open section, but its
   section 7 says it shipped in 0.03 and section 9 says it is live on 16 and 19**; the list is
   behind the text above it, and is carried here as it stands;
3. descriptor comparison with the data extension - answered by ruling on
   2026-10-12 (R4): they share the data-table rendering; and OOM's 0.02 gave the
   descriptors a portable type for it (section 8).

# Sequencing

Scheduled 2026-09-28 at the release manager's direction, after the egress policy
it sits inside. Four gates stood in front of it; three are down, and the last is not
engineering's.

| Gate | State |
| --- | --- |
| X4 and its sub-questions ruled | **DONE 2026-09-28**, as recommended |
| SM579's invocation-mode policy becomes shared, so the proxy can be mode 2 *inside* it | **DONE, AND RELEASED.** `lib/Lazysite/Egress.pm` landed in 0.15.1 - `@MODES` and `may_invoke`, proved equivalent over 960 combinations, and its own comments already name `proxy` as a caller. This row said "the piece being built first" for three days after it was built, which is why the drift gate above now exists |
| The mapper specification filed and merged here | **DONE 2026-10-01.** Filed above with its source hash. It closed three seams, left two open and **found one new piece of work** - the session transport OOM did not have (section 7), which OOM built in 0.03 (RE-FILED 2026-10-13) |
| OOM reachable by this engine (OB7) | **STILL OPEN, and it is the only gate left - but it is a DECISION, not a packaging task.** `perl -MOdoo::Client -e1` fails on this host. This row first said a 0.02 deb had to be built; the release manager's direction of 2026-10-01 corrects that - OOM is under test and will have consumers beyond lazysite, so its delivery shape belongs to all of them. What survives is the requirement on CONTENT: whatever is delivered carries the `Odoo::Ops::*` layer, or there is no scoped mode. See *The direction, 2026-10-01*. OP-25. **RULED 2026-10-12 (R3): the deb, updated to carry what the extension needs.** The exact module list is filed to OOM's inbox (below). Building proceeds against the OOM tree; shipping waits on that deb. **2026-10-13: the deb exists (0.02 to 0.09, /srv/projects/packages) and is not installed on this host** |
| OOM's session transport (per-user path only) | **SHIPPED 2026-10-13, OOM 0.03 (R2)**, live on Odoo 16 and 19 (17/17 checks each). Slices B, C and D no longer wait on OOM; whether to build them is B-Q1. Request filed 2026-10-02, followed up 2026-10-12 (below) |

The first scoped app is the stock-corrections portal's live facts (P1).

# Open: B-Q1 - build the per-user path now that OOM's session transport has shipped (2026-10-13)

**For the release manager. Nothing is built for it, and the plan for B, C and D is unchanged
from the slice table; only their blocker has moved.** R2 ruled that the per-user path waits
for OOM's session transport. It shipped in OOM 0.03 and is live on Odoo 16 and 19, and the
live probes that came with it changed one thing the plan assumed.

**What the probes found** (section 9 of the filed specification, live 2026-10-13, 16 and 19):

- An API key minted as the user authenticates over RPC (`common.authenticate`).
- **`/web/session/authenticate` refuses an API key on both series** (kind `credential`): a web
  session needs the password. OA3's preferred form - use the key once to obtain a session, carry
  the session, discard the key - **does not exist**. OA3's own fallback is to carry the key,
  which OA3 says "is a materially different risk and must not be silently adopted", and R2
  already declined it.
- A two-factor user cannot complete a password session login (Odoo refuses), as OA2 said.
- **A key can be minted for the person, but only by a session that has passed Odoo's password
  identity check** (OOM's `core.user api-key`, live 2026-09-28 and in 0.09; section 9 of the
  filed specification). So "key once, then session" stays impossible in the other direction
  too: a key still needs the password, in a session, once. It does not change the
  recommendation below; it is the only way an API-key strategy could be fed without the
  person pasting a key.
- A portal user is refused a direct write on their own contact over RPC; Odoo's portal controller
  verifies the session identity and applies through its service connection, and OOM's use-case
  test shows the same shape. That is the connection user's path (slice CU) with a verified
  identity, not a per-user write. **OOM 0.09** adds `core.user`, which makes a portal user the
  way Odoo's portal does (the portal wizard's grant, live on 16 and 19), so an operator can
  create the person this pattern signs in.

| Slice | What it needed | What OOM now provides | What lazysite still has to build |
| --- | --- | --- | --- |
| **B** (M): one per-user credential strategy end to end | A transport that signs a person in and carries their session | `Odoo::Transport::Session`: `authenticate(db, login, password)` once, returning the identity (uid, login, name, lang, tz, companies) and an opaque session id; resume with `session => $id`; `destroy` on sign-out; expiry dies as category `session`, a refused login as `credential`, neither retried; `Odoo::Ops::Config->new(credential => 'session', session => $id)` runs every operation as that person (in memory only: a config file may not carry a session) | The sign-in step that takes the password and hands it to OOM without logging, storing or echoing it; the credential cookie (httpOnly, Secure, SameSite, path-scoped, OA4) carrying the session id; replay on each call; clearing on logout and on a `session` fault; outcome 10's re-authentication prompt; a named refusal for a two-factor account; a rate limit on sign-in attempts; the declared minimum raised to the OOM that carries the transport (0.03) when this lands |
| **C** (M): identity cookie, TT exposure, cache fail-closed | The person's Odoo identity once, at sign-in | The identity from `authenticate` (and `session_identity` on a resumed session). **Groups are not in it**: they are read from `res.users`, which the Guard allows, under a field named `groups_id` up to 16 and `group_ids` on 19 | The signed identity cookie with its TTL and refresh (OI1-OI3); the TT namespace (OT1, OT2); the cache fail-closed rule, reusing SM857's mechanism (OI5). The groups read is series-specific Odoo knowledge, so it needs to be an OOM operation or helper, not lazysite code (t/lint/240); that is a small ask of OOM |
| **D** (S-M): shared browser data module, re-authentication prompt | B | Nothing directly. The `session` fault category is the cue for the prompt. CSRF has moved to CU and is already built | The browser module (OA6: fetch, the CSRF token with one retry, the prompt), beside or inside `starter/assets/lazysite-data.js` |
| **F2** (S) | B, C, D | - | The per-user path's SECURITY.md and docs entries |

**Recommendation, sized:**

1. **Build B as a session-only (password) strategy first, then C, then D** - about one working
   session each for B and C and half of one for D (the calibration the slice table already uses:
   one session is about 34 files and 1,540 lines), F2 on the end. The first demonstrable result is
   a person signing in with their Odoo password on a lazysite page and a page rendering their own
   Odoo records, attributed to them in Odoo's own trail.
2. **Do not build the `apikey` strategy (OA3) until it is ruled.** With the key-once form gone it
   is only "carry the key", which R2 declined. If it is wanted, it is a separate ruling with the
   risk written out; if not, outcome 11 ("both session and apikey strategies work") is amended to
   the session strategy alone and two-factor accounts stay unsupported on this path.
3. **For a customer-facing site, consider the connection-user path with a verified identity before
   the per-user write path**: sign the person in over the session transport (B), then run the
   write as the connection user with the verified `partner_id` as a bound parameter - the portal
   pattern OOM tested live. That needs one new binding source (a parameter fed from the verified
   Odoo identity, beside `fixed` and `visitor_param`), about S, and is a decision to take with C.
4. **Ask OOM for the groups read** (above) so C does not put Odoo field names in lazysite.

**Asked:** (a) build B, C, D now, in the order above, or wait; (b) the `apikey` strategy: carry the
key (with the risk documented), or drop it from the outcomes; (c) whether the connection-user path
with a verified identity (3) comes first.

# Where the 2026-10-12 requests were filed

Both in OOM's inbox, in the house filing style, each claim graded with its file and
line:

| Request | Filed | Kind |
| --- | --- | --- |
| The session transport for the per-user path (R2) | `/srv/projects/odoo/oom/inbox/2026-10-12-lazysite-needs-the-session-transport.md` | **A follow-up.** The request itself was filed 2026-10-02 as `2026-10-02-the-session-transport-lazysite-needs-from-oom.md` in the same inbox and is still there unanswered; the follow-up records the ruling, re-measures, and adds what the first left out - logout, and the call surface the Guard wraps |
| The `Odoo::Ops::*` layer in the deb (R3, OB7) | `/srv/projects/odoo/oom/inbox/2026-10-12-lazysite-needs-the-ops-layer-in-the-deb.md` | **New.** The 2026-10-02 note mentioned the 8-of-41 measurement and expressly did not ask, the delivery shape being open then. It names every module the engine will import, the version lazysite will declare in `owns.deps`, two runtime dependencies missing from `debian/control`, and Q3's portable type as an optional ask |
