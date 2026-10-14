# Object-mapper specification (for SM747)

Status: **DRAFT, growing with use** (started 2026-09-28). SM747 — the
lazysite Odoo extension filing — holds open a seam for "the
object-mapper specification ... to be merged into this spec". This is
that document, written from what has been built and exercised against
Odoo, not in advance of it. Not filed; the owner decides when.

Every claim below says what it rests on: **tested** (offline suite,
fake Odoo), **source** (read from the Odoo 16.0 source), **live**
(verified against a named instance and series), or **design**
(decided, not yet exercised).

## 1. Layers

| Layer | Modules | Responsibility |
|---|---|---|
| Mapper | `Odoo::Client`, `Model`, `Record(Set)`, `Commands`, `Transport::*`, `Error` | RPC, introspection, read/write, x2many grammar, fault classes |
| Operations | `Odoo::Ops::*` | named operations, scope guard, profiles, plan/apply/journal/revert, audit |
| Function packs | `Odoo::Ops::CRM::*`, `Odoo::Ops::Comms::*` | the business operations |

The extension would consume the mapper and the operations layer as the
`libodoo-oom-perl` package (OB7), never a copy.

## 2. Transport discipline (OB6) — tested

- No redirect is followed; a 3xx dies as kind `refused` (code
  `redirect`) naming the target. (HTTP::Tiny follows a 303 even on
  POST by default; switched off.)
- `max_response_bytes` caps an answer; over it dies `refused`
  (`oversize`), not retried.
- TLS verification on. Only kind `transport` is retried.

## 3. Fault kinds (OB5) — tested (wire shapes from source)

`Odoo::Error->fault_category`: `access` (AccessError), `credential`
(AccessDenied), `session` (SessionExpiredException), `validation`
(ValidationError, UserError), `missing` (MissingError), `other`.
JSON-RPC carries the class in `error.data.name`; XML-RPC only in the
traceback, from which it is recovered. Plus kinds `transport`,
`refused`, `config`, `usage`.

## 4. Named operations and scope (OB2, OM2) — tested

An operation declares `op_name`, `params` (typed, validated, unknown
names refused), `read_scope` and `write_scope` as `{model => [methods]}`.
`Odoo::Ops::Guard` wraps the transport and refuses any `execute_kw`
outside the running operation's scope **before it leaves**; base scope
is `common.*`, `fields_get` on any model, `res.users.read`. This is
SM747's scoped mode: a named query is an operation with a declared
scope and bound params. General mode (OB3) is the absence of the guard,
and applies only with the user's own credential.

## 5. Plan / apply (the UI's preview-then-confirm) — tested

Write operations only plan. A plan is JSON: changes (create, write,
unlink, call, custom, skip, hold) each in a named bucket with the
before-image it saw; buckets sum to the input; sealed by fingerprint;
bound to an instance; `applied: 0`. Apply refuses read-only configs,
other instances, edited plans, re-applies and stale before-images;
reads every write back; journals each change as it happens;
`applied: 1`. Revert is itself a plan. A lazysite app would present the
plan's buckets as the preview and call apply on confirm.

## 6. Audit (OB8) — tested

One record per RPC call, fixed fields only: `ts actor login service
model method op outcome fault_category ms`. The sink refuses any other
key, so payload or credential cannot be added by accident.

## 7. Credential strategies (OA1) — session shipped (0.03), live on 19

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
users cannot complete a password session login (Odoo refuses). Groups
are not in the identity: read `res.users` (in the Guard's base scope),
minding the field name per series (`groups_id` to 16, `group_ids` on
19).

## 8. Field descriptors — tested (shape and portable type), live on 19

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
load. A consumer that meets a field without `portable_type` refuses to
render it by name - the mapping never lives on the consumer's side.

**Display reads** return `rows` (a list of hashes keyed by logical
field) beside `fields` (those descriptors keyed the same way), built
with `Operation->fields_for($logical_model, @fields)`. `crm.export`
does so with `inline=1`; its report keys are `count`, `file`,
`fields`, `rows`.

## 9. Series — tested (mechanism), live pending

Logical→physical profiles per pack and series, validated against live
`fields_get`; nearest-lower fallback with a warning. Behaviour beyond
names (e.g. sending mail) dispatches per series and refuses on an
unprobed one.

| Behaviour | 16 | 17 | 18 | 19 | 20 |
|---|---|---|---|---|---|
| crm profile | live 2026-09-28 (16.0-20250909): 42/42 fields, restricted CRM user; live 2026-10-13 (local cluster): 43/43 | not probed | live 2026-10-13: the 16 profile validates 43/43 (loader warns it is the 16 file) | live 2026-10-13: the 16 profile misses `crm.lead.mobile` (removed); `profiles/crm/19.yaml` maps it to `~` and validates 42/42 | — |
| `crm.inspect` and `crm.export` (counts by type/stage/tag/source/team/salesperson; rows + descriptors with portable types, no faults) | live 2026-10-13: 9 leads, 31 fields | not probed | live 2026-10-13: 6 leads, 31 fields | live 2026-10-13: 12 leads, 30 fields (no `mobile`); same run over json2: inspect ok | — |
| crm profile | live 2026-09-28 (16.0-20250909): 42/42 fields, restricted CRM user; live 2026-10-13 on the local 16: 9 models, 50 fields with `res.partner` mapped (`core.check`) | 16 file validates live (TEST-RESULTS, series 17 and 18) | live 2026-10-13: `profiles/crm/18.yaml`, 9 models, 50 fields | live 2026-10-13: `profiles/crm/19.yaml`, 9 models, 49 fields; `crm.lead.mobile` is absent on 19 (the 16 file named it) | — |
| `/jsonrpc` + `execute_kw`, API-key auth | live (jpm clone; local cluster 16.0 2026-10-13) | — | — | live 2026-10-13 (19.0, odoo-cluster) | — |
| `copy` answers a list of ids (multi-record since 18) | single id | — | — | live 2026-10-13: `Model->copy` returns one id for one id on every series | — |
| html field written as plain text reads back wrapped in `<p>` | verbatim | — | — | live 2026-10-13 | — |
| `res.partner.date` | present | — | — | absent, live 2026-10-13 | — |
| read/write/unlink/x2m commands/verify_credentials (t/98, t/99) | live (jpm clone; local cluster 16.0 2026-10-13) | — | — | live 2026-10-13 | — |
| a pallet moved into `WH/Output` by a validated internal transfer reads fully reserved | not seen: the relocate-and-return test ran clean (t/94, 2026-10-13) | not probed | not probed | observed 2026-10-13 (t/94): `reserved_quantity` 8 of 8 after the transfer; cause not isolated | — |
| the opposite transfer of a transfer that left a package split is refused (a package in two places) | refusal reproduced offline only (t/33, the stock fixture); the live mirror undo was not run in this piece; the relocate undo applied live 2026-10-13 (t/94) | not probed | not probed | the relocate undo applied live 2026-10-13 (t/94); the mirror undo not run live | — |
| session transport: authenticate, call_kw, identity, destroy, expiry (t/97) | live 2026-10-13: 17/17 | — | — | live 2026-10-13: 17/17 | — |
| sale: basket as draft order, lines by x2m commands, action_confirm, invoice via `sale.advance.payment.inv` + `create_invoices`, `action_post`, payment via `account.payment.register` + `action_create_payments` (t/95) | live 2026-10-13: paid | — | — | live 2026-10-13: paid | — |
| chart of accounts on a fresh db | `l10n_generic_coa` is a module: `ir.module.module.button_immediate_install` over RPC loads the chart for a company without one; `res.company.chart_template_id` says so (live 2026-10-13) | — | — | `account.chart.template.try_loading('generic_coa', company=)`; `res.company.chart_template` (live 2026-10-13) | — |
| crm.lead create + ir.attachment (image) + message_post note (t/95) | live 2026-10-13 | — | — | live 2026-10-13 | — |
| hr.expense submit | report: `hr.expense.sheet` create + `action_submit_sheet`, state `submit` (live 2026-10-13) | — | — | no sheet: `hr.expense.action_submit`, result in `approval_state` (auto-approved when the submitter is the approver), live 2026-10-13 | — |
| portal user writes their own res.partner over RPC | REFUSED (access) live 2026-10-13, same pattern | — | — | REFUSED (access) live 2026-10-13: the app verifies the session identity (`partner_id`) and applies through its service connection, as Odoo's portal controller does | — |
| portal user reads crm.lead | refused (access), live | — | — | refused (access), live | — |
| API key at `common.authenticate` (RPC) | live 2026-10-13: ACCEPTED (key minted as the user; an earlier probe minted as the superuser was refused and misreported) | — | — | live 2026-10-13: ACCEPTED (same correction) | — |
| API key accepted at `/web/session/authenticate` | live 2026-10-13: REFUSED (credential) - a web session needs the password; "key once, then session" does not exist | — | — | live 2026-10-13: REFUSED (credential) | — |
| module enable over RPC (`button_immediate_install`), `ir.config_parameter.set_param`, `res.config.settings` create + `execute` | live 2026-10-13 (l10n_generic_coa) | — | — | live 2026-10-13 (survey; group_multi_currency; a parameter) | — |
| core.import: keyed create/update of res.partner (country by code, tag created when missing), product.template by default_code, product.product barcode by default_code; re-run all unchanged (t/96) | live 2026-10-13: 31/31 | — | — | live 2026-10-13: 31/31 | — |
| stock profile: quant, location, package, lot, picking, picking type, move, move line, sale line, order, wizards | live 2026-10-13: 12 models, 88 fields; move line `reserved_uom_qty`/`qty_done`, `stock.immediate.transfer` | profile 17.yaml: one `quantity` + `picked`, no immediate wizard (pending live) | — | live 2026-10-13: 11 models, 85 fields; `stock.quant.package` renamed `stock.package`; `stock.move.name` absent | — |
| a transfer that leaves a package in two locations | REFUSED at validation (SA8), live 2026-10-13 (the mirror netting's reversal) | — | — | ACCEPTED, live 2026-10-13 (same reversal) | — |
| `stock.quant.create` with `quantity` (no inventory mode) and `write` of `package_id`/`quantity` by an administrator | ACCEPTED, live 2026-10-13 (how the test seeds anomalies; SB3 on the live site) | — | — | ACCEPTED, live 2026-10-13 | — |
| internal picking type of a one-step warehouse | archived (`active` false); a picking of it validates, live 2026-10-13 | — | — | same | — |
| `product.category.property_valuation` values | `manual_periodic`, live 2026-10-13 | — | — | `periodic`, live 2026-10-13 | — |
| context `lang` naming a language that is not installed | ACCEPTED silently (served in the user's language), live 2026-10-13 (`fr_FR`, `xx_XX`) | not probed (the instance shares the host's one spare alias with 18) | REFUSED on every call: "Invalid language code", live 2026-10-13 - the live harness now sends a lang only when the config names one | REFUSED on every call, live 2026-10-13 (`en_GB` installed there is accepted) | — |
| root product category name | `All` (live 2026-10-13) | — | — | `Goods` (live 2026-10-13) - resolve categories by name only with that in mind | — |
| serving slot after an external module install | needs a restart to see new models (live 2026-10-13); the cluster's module-install does it | — | — | same | — |
| `auth_ldap` server model | `res.company.ldap`, not `ldap.server`: `company`, `ldap_server`, `ldap_server_port`, `ldap_base`, `ldap_filter`, `ldap_binddn`, `ldap_password`, `ldap_tls`, `create_user`, `user` (the template), `sequence`; no name field. Live 2026-10-13 (t/24, 39/39); the admin reads `ldap_password` back over RPC | not probed (the instance shares the host's one spare alias with 18) | same fields, live 2026-10-13 (t/24, 39/39, after `module-install demo18.localhost auth_ldap`) | same fields, live 2026-10-13 (t/24, 39/39) | — |
| `ir.module.module.update_list` over RPC as the administrator | ACCEPTED, live 2026-10-13 (t/24: a missing addon name triggers it, then is held `unknown-module`) | not probed | ACCEPTED, live 2026-10-13 | ACCEPTED, live 2026-10-13 | — |
| `ir.config_parameter.unlink` over RPC as the administrator | ACCEPTED, live 2026-10-13 (t/24) | not probed | ACCEPTED, live 2026-10-13 | ACCEPTED, live 2026-10-13 | — |
| `fields_get` of `res.partner` for the mapping skeleton | live 2026-10-13 (t/24): relations, selections and magic columns as the skeleton expects | not probed | live 2026-10-13 | live 2026-10-13 | — |
| two-step delivery (`delivery_steps` = `pick_ship`): what confirming a sale order makes | a pick and a delivery, live 2026-10-13 (t/93) | not probed | the pick only; the delivery is made when the pick is validated, by the route's push rule `Output -> Customers`, live 2026-10-13 (t/93) | the pick only, as 18; `stock.rule` action `push` listed, live 2026-10-13 (t/93) | — |
| writing `delivery_steps` back to `ship_only` | not probed | not probed | REFUSED while the output location holds stock ("You can't disable locations WH/Output because they still contain products"), live 2026-10-13 | not probed | — |
| a pick's reserved move lines: who makes and writes them | created by user 1, written by the confirming user in the same second, live 2026-10-13 (t/93, first run) | not probed | not probed | not probed | — |
| domain term `product_id != 0` on `stock.move.line` | matches no record (0 rows where lines existed), live 2026-10-13; name the product | not probed | not probed | not probed | — |
| lot of a product with `use_expiration_date` and `expiration_time` 0 | `expiration_date` = `create_date`, live 2026-10-13 | not probed | same, live 2026-10-13 | same, live 2026-10-13 | — |
| `expiry.picking.confirmation` on validating a pick that draws such a lot | opened once the clock passed the creation time (SC4), live 2026-10-13 | not probed | not probed | asked for a lot with `expiration_date` 2030 and `removal_date` at creation, after the backorder wizard; none once all four lot dates were 2030, live 2026-10-13 | — |
| reservation of a lot whose lot dates are past, orders made seconds after the lots | not observed (reserved) | not probed | not probed | the second and third orders' picks stayed `confirmed`, nothing reserved; with the dates in 2030, `assigned` with the reservation, live 2026-10-13 (observed together, not isolated) | — |
| `process_cancel_backorder` on a pick or delivery validated below demand | closes it, no backorder picking left, live 2026-10-13 | not probed | same, live 2026-10-13 | same, live 2026-10-13 | — |
| adding a line (`picking_id`, `qty_done`/`quantity`, no `move_id`) to a done pick (SA3) | a done move with no `sale_line_id`, no `move_dest_ids`; `qty_delivered` unmoved, live 2026-10-13 | not probed | same, live 2026-10-13 | same, live 2026-10-13 | — |
| the same on the done delivery, then `write` of `sale_line_id` and `move_orig_ids` `(4, stranded)` | `qty_delivered` rises by the quantity (SC1); the stranded move gains its `move_dest_ids`, live 2026-10-13 | not probed | same, live 2026-10-13 | same, live 2026-10-13 | — |
| `date_done` on a validated picking, `date` on its moves and lines (SC6) | writable, live 2026-10-13 | not probed | same, live 2026-10-13 | same, live 2026-10-13 | — |
| `message_post` on `stock.picking` with `author_id`, `email_from`, `subtype_xmlid` `mail.mt_note` (SD1) | posts as a Note, live 2026-10-13 | not probed | same, live 2026-10-13 | same, live 2026-10-13 | — |
| an order with a draft invoice (a fixed-amount down payment) | `invoice_ids` readable by an accounting user; held `invoiced`, live 2026-10-13; the access error for a user without accounting rights not reproduced | not probed | same, live 2026-10-13 | same, live 2026-10-13 | — |
| read_group row count key `<field>_count` | live (crm.inspect) | — | — | — | — |
| read_group row count key (V14) | `<field>_count` for a lazy grouping, `__count` for `lazy=false`; live 2026-10-13 (crm.lead by type, tag_ids, stage_id) | not probed | same as 16, live 2026-10-13 | same as 16, live 2026-10-13 - not a series difference; `crm.inspect` reads either key | — |
| API key minted over the web session (make_key → identitycheck → run_check), then password spent | live 2026-09-28 | — | — | — | — |
| send via composer (mass_mail on one lead, V15) | live 2026-10-13 (t/91 16/16): composer driven by context `active_ids`, field `auto_delete_message` off; copy in the lead's history is `message_type` `email`; mail.mail in state `exception` with no outgoing server (sent at once) | source (17.0 composer: as 18); sender implemented, plan says so | live 2026-10-13 (t/91 16/16): `res_ids` text, `force_send` off; copy is `email_outgoing`; mail.mail `outgoing`, queued | live 2026-10-13 (t/91 16/16, also over json2): as 18 | — |
| composer fields `mail.compose.message` | `res_id`, `auto_delete_message` present; `res_ids`, `auto_delete_keep_log`, `force_send`, `use_exclusion_list` absent (live 2026-10-13) | `res_ids`, `auto_delete_keep_log`, `force_send` in the source; no `auto_delete_message` | `res_id` and `auto_delete_message` absent (a create naming `auto_delete_message` is refused: "Invalid field"); `res_ids` (text, a list), `auto_delete`, `auto_delete_keep_log`, `force_send`, `use_exclusion_list`, `partner_ids` present (live 2026-10-13) | as 18, and `composition_comment_option`, `notify_*` fields added (live 2026-10-13) | — |
| `/json/2/<model>/<method>` (V5) | absent: 404 HTML page (live 2026-10-13) | not probed | absent: the unauthenticated request is redirected (303) to the login page; no `json/2` in the 18.0 source (live 2026-10-13) | present (module `rpc`, `rpc/controllers/json2.py`), live 2026-10-13 | — |
| `/json/2` authentication | n/a | not probed | not probed (no API key minted on 18 for this) | `Authorization: Bearer <API key>` only (route `auth='bearer'`): no header 401 "User not authenticated, use an API Key with a Bearer Authorization header."; the password as bearer 401 "Invalid apikey"; the web session cookie 401 "Missing Authorization or Sec-headers"; live 2026-10-13 | — |
| `/json/2` database selection | n/a | not probed | not probed | header `X-Odoo-Database: <db>`; optional with one database (live 2026-10-13, the instance has one); the 19.0 `test_webjson2` suite: more than one database and no header, or a wrong one, answers a 404 HTML page | — |
| `/json/2` error shape | n/a | not probed | not probed | HTTP status plus JSON `{name, message, arguments, context, debug}` (`debug` is a traceback, never copied by the transport). Missing record 404 `odoo.exceptions.MissingError`; unknown model 404 `werkzeug.exceptions.NotFound`; unknown method 404 (the message names `model.method`); `UserError` 422; bad field in a create or domain 500 `builtins.ValueError`; bad argument name 500 `builtins.TypeError`; missing argument 422 `UnprocessableEntity`; ids given to a model method 422; live 2026-10-13 | — |
| `/json/2` calling convention | n/a | not probed | not probed | the body is the method's keyword arguments by name, plus `ids` (record methods) and `context`; no positional arguments (`default_get` takes `fields`, `write` takes `ids` and `vals`, `create` takes `vals_list`); `create` answers a list of ids, `copy` a list, `write` true; `common.version` is not served here: `/web/webclient/version_info` answers unauthenticated; the key owner's uid comes from `res.users/context_get`; live 2026-10-13 (t/93 18/18, t/95 7/7, t/98 and t/99 45/45 over `transport = json2`) | — |
| `properties` fields (V3): `crm.lead.lead_properties` (definition on `crm.team.lead_properties_definition`, type `properties_definition`) | present, live 2026-10-13: `fields_get` type `properties`, stored; a read answers a list of definition hashes each with its `value`; create and write take a list of `{name, value}`; the default read, `search_read`, `find` and a Record read it without a fault; `Portable::describe` gives no type; filtering by `lead_properties.<name>` faults ("'Properties' object has no attribute 'auto_join'"); writing a dict `{name: value}` replaces the whole set, unlisted values reading `0` (t/92 11/11) | not probed | as 16, except that a domain on `lead_properties.<name>` works (t/92 11/11) | as 18, except that after a dict write the unlisted values are absent from the read (t/92 11/11) | — |
| `project.task` (the other properties model named in V3) | not installed | not probed | not installed | not installed | — |
| send via composer (mass_mail on one lead) | source | — | — | — | — |
| composer field for keeping a copy in the record's history | `auto_delete_message` (source 16.0 mail.compose.message) | `auto_delete` + `auto_delete_keep_log` (source origin/17.0) | same as 17 (source 18.0) | same as 17 (source 19.0) | — |
| a sender with no email address and `message_post` (a lead note) or a lead created for another salesperson | REFUSED "Unable to send message, please configure the sender's email address", live 2026-10-13 (`tmp/probe-noemail.pl`); the same create under `mail_auto_subscribe_no_notify` ACCEPTED | refused (source origin/17.0 `_message_compute_author` raises); not probed, 17 unreachable | REFUSED, live 2026-10-13, as 16 | ACCEPTED both, live 2026-10-13 (source 19.0: `_message_compute_author` has no `raise_on_email`) | — |
| `button_validate` subscribes the validating user | yes (source 16.0) | yes (source origin/17.0) | yes (source 18.0) | no (source 19.0: no `message_subscribe` in `stock_picking.py`) | — |
| the "package in two places" refusal counts | every quant of the package with a quantity or a reservation, negative ones too (source 16.0 `stock_move._action_done`; the mirror reversal REFUSED, live 2026-10-13) | only quants with a positive quantity (source origin/17.0) | same as 17 (source 18.0) | same as 17 (source 19.0; the mirror reversal ACCEPTED, live 2026-10-13) | — |
| `crm.lead` unarchive: clears `lost_reason_id`, re-scores | in `toggle_active` (source 16.0) | in `toggle_active` (source origin/17.0) | in `toggle_active` (source 18.0) | in `action_unarchive`; no `toggle_active` on the lead (source 19.0) | — |
| `mail.activity` refuses an assignee who cannot read the record when the activity is not automated | yes, `_check_access_assignation` (source 16.0) | method kept but deprecated and not called (source origin/17.0 docstring) | no such method (source 18.0) | no such method (source 19.0) | — |
| `activity_schedule` marks the activity `automated` unless `automated` is passed | yes (source 16.0) | yes (source origin/17.0) | yes (source 18.0) | yes (source 19.0) | — |
| `crm.note` through the lead's `message_post` route (`subtype_xmlid mail.mt_note`), message id read back | not run | not run | not run | live 2026-10-13: applied, verified 1 (`ODOO_OOM_BEHAVIOURS` pointing at a one-route file) | — |
| apply invariants: `probability-manual` and `lot-totals-internal` read around an apply | live 2026-10-13: `crm.tag` apply, 10 open leads follow their automated score before and after (preexisting, not the apply's); `stock.net` t/94 31/31 | not run (unreachable) | live 2026-10-13: `crm.tag` apply, 10 before and after; t/94 31/31 | live 2026-10-13: `crm.tag` apply, 17 before and after; t/94 31/31 on the third run (see TEST-RESULTS: the first two failed when another session moved stock the sum read) | — |
| `res.partner` address written on a company reaches its children of type contact, not those of another type; written on a contact it stays there | live 2026-10-13 (t/92, 28/28) | source origin/17.0 (no upstream step); not live | live 2026-10-13 (t/92, 28/28) | the contact's address is also written on the company: live 2026-10-13 (t/92, 28/28; source 19.0 `_fields_sync` "To UPSTREAM") | — |
| `res.partner` vat written on a company replaces its non-company children's; written on a contact | stays on the contact, live 2026-10-13 | source origin/17.0 (as 16); not live | stays on the contact, live 2026-10-13 | written on the company too (`vat` is a synced commercial field), live 2026-10-13 | — |
| `res.partner` Tax ID check (`base_vat`) on an invalid number | REFUSED at write and create, with or without a country, accepted under `no_vat_validation`, live 2026-10-13 (`base_vat` installed on the local 16 for the run) | not probed | same as 16, live 2026-10-13 (`base_vat` installed for the run) | REFUSED with a country; ACCEPTED when the partner has no country (source 19.0 `_run_vat_checks` returns at once), live 2026-10-13. `base_vat` was already installed there | — |
| `res.partner` `company_type` (writes `is_company`), `commercial_partner_id`, `display_name` "Company, Contact", website `http://`, `email_normalized` lower-cased and a malformed address accepted | live 2026-10-13 (t/92) | not probed | live 2026-10-13 (t/92) | live 2026-10-13 (t/92) | — |
| `res.users.has_group` over RPC (doctor's group test) | a model method: `execute_kw(res.users, has_group, [group])` answers; with ids first it faults "takes 2 positional arguments but 3 were given" (live 2026-10-13, `oom-ops doctor`) | not probed | not probed | a record method: `[[uid], group]` (live 2026-10-13, `oom-ops doctor`) | — |
| `common.db.list` over `/jsonrpc` (LIST_DB) | refused: `odoo.exceptions.AccessDenied`, code 200 (live 2026-10-13, the local cluster, `oom-ops doctor`) | not probed | not probed | refused: `AccessDenied` "Access Denied", code 0 (live 2026-10-13, as 16) | — |
| `/web/login` through the cluster proxy | HTTP 200 with a `Date` header (live 2026-10-13) | not probed | not probed | HTTP 200 with a `Date` header (live 2026-10-13) | — |
| portal user made the way Odoo's portal does (core.user, 0.09): `portal.wizard` create with `partner_ids`, its computed `portal.wizard.user` line, `action_grant_access` on the line; the user's login is the line's email, normalised | live 2026-10-13 (t/35-core-user-live.t 40/40); the wizard exists, `portal.mail_template_data_portal_welcome` | source origin/17.0: as 16 (the modal action loses `view_type`); 17 unreachable, not probed | live 2026-10-13 (40/40); source 18.0: a revoked user is archived and kept in the portal group; the grant always writes `active` and the portal group | live 2026-10-13 (40/40); source 19.0: `group_ids`; the invitation is `auth_signup.portal_set_password_email` sent to the user | — |
| the portal wizard's invitation email | sent at the grant, `force_send`; with no outgoing server the `mail.mail` is left in state `exception` and the grant succeeds, live 2026-10-13 | not probed | same as 16, live 2026-10-13 | a `mail.mail` in state `exception` with no `email_to` (the recipient is the partner), live 2026-10-13 | — |
| `res.users` created with no groups named | gets the template user's groups: the local 16 gives a new user Sales, Inventory, Invoicing, Expenses and Employees administrator groups among others (live 2026-10-13); naming `groups_id` `(6, 0, [base.group_user])` gave a user who cannot read `crm.lead` (t/36-core-attach-live.t) | not probed | not probed | the new user held "Role / User" only (live 2026-10-13) | — |
| `password` written on `res.users` by the administrator over RPC | ACCEPTED; `common.authenticate` with it answers the user's uid, and answers false once the user is archived, live 2026-10-13 | not probed | ACCEPTED, live 2026-10-13 | ACCEPTED, live 2026-10-13 | — |
| API key minting path (core.user `api-key`): a web session as the user; `res.users.apikeys.description` create `{name}` + `make_key` answers the identity-check action (`res.users.identitycheck`, `res_id`); the check reads the password, then `run_check` answers the action `res.users.apikeys.show` whose `context.default_key` is the key. The acting user needs the identity check (10 minutes per session) | the password is written to the wizard's `password` field, then `run_check`; live 2026-10-13 (40/40) | same as 16 (source origin/17.0); not probed | same as 16, live 2026-10-13 (40/40); the wizard adds `duration` and `expiration_date` | the password goes in the call's context (`context.password`; the wizard's `password` field is not stored), then `run_check`; live 2026-10-13 (40/40) | — |
| who may mint an API key | internal users (`user_has_groups('base.group_user')`, source 16.0); a portal user is refused | source origin/17.0: as 16 | source 18.0: `_is_internal()` | source 19.0: `_is_internal()`; live: the plan holds a portal user `not-internal` before any call | — |
| default expiry of a key minted by a user who is not an administrator | none (no expiry field on `res.users.apikeys`), live 2026-10-13 | none (source origin/17.0 `_generate(scope, name)`) | the day after the creation date at midnight (`expiration_date`; the user's groups' `api_key_duration` allows one day), live 2026-10-13 | the same, live 2026-10-13 | — |
| `action_reset_password` on a user with an email, no outgoing mail server | FAILS: "Unable to connect to SMTP Server" (the call sends with `raise_exception`), live 2026-10-13 | not probed | applied, live 2026-10-13 | applied, live 2026-10-13 | — |
| `ir.attachment.checksum` and `file_size` | `checksum` is the SHA-1 (hex) of the raw bytes, `file_size` their count; both set at create, live 2026-10-13 (t/36-core-attach-live.t 37/37) | not probed | same, live 2026-10-13 (37/37) | same, live 2026-10-13 (37/37) | — |
| attachment access for a user who cannot read the record the attachment is on (an internal user holding only `base.group_user`, an attachment on a `crm.lead`) | `read` REFUSED: "You are not allowed to access 'Lead/Opportunity' (crm.lead) records" (category access); `search_read` by id answers an empty list; `/web/content/<id>?download=true` with the user's web session answers HTTP 404; an attachment on a partner is read normally. Live 2026-10-13 | not probed | the same checks pass, live 2026-10-13 | `read` REFUSED ("Uh-oh! Looks like you have stumbled upon some top-secret records."), search empty, `/web/content` 404, live 2026-10-13 | — |
| binary path of an attachment | `read` of `datas` over RPC answers base64 of the content; `/web/content/<id>?download=true` with a session cookie answers the bytes (HTTP 200, same SHA-1), live 2026-10-13 | not probed | same, live 2026-10-13 | same, live 2026-10-13 | — |

## 10. Onchange and x2many (SM747 seam)

Writes never invoke onchange (mapper decision, `docs/USAGE.md`): the
tools set only stored fields they name, and a created lead is what the
API creates, not what a form would. x2many values go through
`Odoo::Commands`; operations add tags by `(4, id)` and never replace a
set unless told to (`on_match: overwrite`).

## Open

- Live verification on the v16 CRM account (pending).
- Session transport for OA2.
- Descriptor comparison with the data extension.
