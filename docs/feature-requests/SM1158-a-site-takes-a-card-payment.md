---
id: SM1158
title: "SM1158: a site takes a card payment, and Odoo is told what was paid"
subtitle: "The plan for L6: a payments extension with a provider seam, Stripe first, through Stripe's hosted Checkout. The site starts the payment for an Odoo quotation, receives Stripe's signed webhook once, and hands the facts to Odoo through a named OOM operation. Odoo stays private and does the accounting."
brand: plain
standard-margins: true
status: candidate
raised: 2026-10-17
raised-by: "release manager, 2026-10-17 (L6, via the OOM agent)"
area: payments
status-note: "PLANNED; rulings R1-R5 (L6's five questions) accepted by the release manager 2026-10-17 (\"all rulings accepted\"). Nothing built. Slices S0-S7; S5 and S6 wait on two asks of OOM (A1, A2); the account postings (O1) and four other owner questions are open."
---

# The request

L6, filed 2026-10-17 by the OOM agent at the owner's request for the expected
e-commerce project (`lazysite/inbox/2026-10-17-L6-taking-a-payment-stripe-first.md`):

> An e-commerce shop will be a lazysite site, with Odoo behind it through the
> Odoo extension and OOM.
> - **Payments:** Stripe first, others later.
> - **Perl has payment-provider modules**, so taking the payment may be
>   lazysite's part.
> - **All accounting and reconciliation stay in Odoo.** The owner will specify
>   the account postings.
>
> A way for a site to take a payment and hand the facts to Odoo:
> 1. **Start the payment** with the provider (for Stripe, a Checkout Session or a
>    Payment Intent) for an order the site knows (an Odoo quotation, by
>    reference).
> 2. **Receive the provider's webhook**, verified by its signature, idempotent (a
>    webhook delivered twice is applied once), and recorded.
> 3. **Hand the result to Odoo** through a named OOM operation: the order
>    reference, amount, currency, the provider's payment id and fees. The posting
>    itself is the owner's to define, made in Odoo by OOM.

It asked five questions: where the payment code lives, how the secrets are
stored, where card data goes, which Perl modules, and Odoo's own
`payment_stripe` as the alternative. OOM's side is
`/srv/projects/odoo/oom/inbox/2026-10-17-ecommerce-project-expected.md`: a basket
is an Odoo quotation, confirmation reserves stock, the invoice is posted and the
payment registered and reconciled in Odoo, every operation through OOM.

# What exists today (2026-10-17)

Read from the code on `main` at b9611fe5a.

1. **A paywall that trusts a header, and no payment.** A page whose front
   matter says `payment: required` is served `402` with an x402
   `X-Payment-Response` unless the caller is in a bypass group or the request
   carries `X-Payment-Verified: 1` (`lazysite-processor/gates.pm:34`
   `peek_payment`, `:46` `check_payment`, `:91` `serve_402`). The header is
   believed only from a trusted proxy: `apply_trust_gate` strips
   `HTTP_X_PAYMENT_*` and the custom `payment_header_*` names otherwise
   (`lazysite-processor.pl:578-662`). Proof of payment is delegated upstream
   (`starter/docs/payment.md:17-19`, `:131-152`). Nothing in lazysite talks to a
   payment provider, keeps a payment record or knows an order.
2. **A demo, and only a demo.** `plugins/payment-demo.pl` simulates an x402
   payment with an HMAC-signed cookie, `lazysite_payment_demo`, for one hour
   (`:2-5`, `:76-77`, `:109-127`). It is `unlisted` (`:45-48`) and says it is
   not for production.
3. **`Lazysite::Egress` is the outbound policy, not the transport.** It answers
   "may this caller cause this callee to be invoked" (`lib/Lazysite/Egress.pm:87`
   `may_invoke`, the three modes at `:57`) and "has this happened too often"
   (`:158` `within_caps`, an uncountable axis refuses). Its header says the
   transport and the credentials are elsewhere (`:33-42`). The transport an
   operator-chosen destination uses is the connector's `LWP::UserAgent` with
   `max_redirect => 0` and a `max_size` cap
   (`lib/Lazysite/Manager/Connectors.pm:765-770`, the reasons at `:720-764`);
   `Lazysite::Fetch` is the SSRF-guarded one for content-chosen URLs
   (`lib/Lazysite/Fetch.pm:45-48`). `libwww-perl` is a Recommends of the
   engine package, not a Depends (`debian/control:28-34`).
4. **How an extension secret is stored.** The Odoo connection user's key:
   one file per account under `lazysite/odoo/keys/`, written through a 077 umask
   to a temporary file and renamed into place, so it is 0600 from the moment it
   exists, in a 0700 directory (`lib/Lazysite/Odoo/Secret.pm:57-82`); one line,
   printable, at most 512 characters (`:59-65`); never returned or logged;
   `has_key` answers 1, 0 or undef when the file exists and cannot be read
   (`:38-52`). The connector secrets are one 0600 JSON beside the store, set on
   their own and never listed, `has_secret` three-state
   (`lib/Lazysite/Manager/Connectors.pm:263-280`, `:328-346`).
   `Lazysite::Odoo::Secret`'s paths are Odoo's (`:27`); nothing generic exists.
5. **The Odoo extension (SM747), built.** One function sends,
   `Lazysite::Odoo::call` (`lib/Lazysite/Odoo.pm:733`), after the gate (`:454`),
   with one fixed-field line per call in `lazysite/odoo/calls.jsonl`
   (`record_call`, `:318`). A binding is a handler of type `odoo`: `operation`,
   `params`, `fixed`, `visitor_param`, `modes`, `apply`
   (`confirm`|`immediate`), per-visitor and per-binding caps
   (`lib/Lazysite/Handlers.pm:282-326`). A public write applies unattended only
   when the binding says `apply: immediate` (SM747 Q1). The visitor key is 256
   server-minted bits in an `HttpOnly; SameSite=Strict` cookie, signed; the CSRF
   token is an HMAC of it (`lib/Lazysite/Odoo/Visitor.pm:88-129`). The page
   endpoint `lazysite-odoo.pl` checks the visitor token or the session token on
   every POST (`:237-261`) and caps a body at 64 KB (`:176-178`); the extension
   declares it in `owns.endpoints` (`plugins/odoo.pl:83-95`). The scheduled
   mode exists, and a form runs a binding as `public` (`Handlers::_to_odoo`).
6. **Forms and outcome codes (SM1124).** A no-JS form post is answered `303`
   back to the same-site page it came from, carrying a code, never a sentence
   (`plugins/form-handler.pl:1541-1559` `_redirect_back`; the tables
   `%OUTCOME_SAID` `:114`, `%REFUSAL_SAID` `:133`). The processor holds the same
   wording (`lazysite-processor/forms.pm:608` `_form_outcome_banner`, `%REFUSED`
   `:659`), and t/lint/156 keeps the two in agreement. The form handler
   redirects only to the site's own page; it has no outcome that sends a
   visitor to another host.
7. **CSRF.** The manager API's gate is `Lazysite::Manager::Csrf::csrf_refusal`
   (`lib/Lazysite/Manager/Csrf.pm:32`), a session-bound token on every POST;
   public endpoints use the visitor-bound token of fact 5.
8. **No inbound webhook receiver exists.** Nothing in `lib/`, `plugins/` or the
   CGIs accepts a signed call from a third party; connectors and the Odoo
   extension only call out. The daemon runs engine jobs that retry outside a
   request, for example the notification outbox
   (`lib/Lazysite/Daemon/Jobs.pm:230` `notify_outbox`).
9. **OOM has no payment operation (tree 0.28, read 2026-10-17).** The Documents
   pack has `sale.confirm`, `sale.cancel`, `account.post`, `account.draft`,
   `account.cancel` (`Odoo/Ops/Documents/`); there is no behaviour file for any
   payment model (`behaviours/`), so `core.wizard` cannot reach
   `account.payment.register` yet, as OOM's own note says.
10. **Perl modules on this host** (`perl -MModule -e1`, and the trixie package
    lists in `/var/lib/apt/lists/`, read without network):

    | Module | Here |
    |---|---|
    | Net::Stripe, Business::Stripe, WebService::Stripe, Stripe | not installed; **no Debian trixie package** (main lists 4,270 `lib*-perl` packages, none for Stripe; the only Stripe client packaged is `python3-stripe`) |
    | Business::OnlinePayment | not installed |
    | Digest::SHA | 6.04 (core) |
    | HTTP::Tiny | 0.088 (core) |
    | LWP::UserAgent, LWP::Protocol::https | 6.78, 6.14 (`libwww-perl`, already a Recommends) |
    | IO::Socket::SSL | 2.089 (already a Recommends) |
    | JSON::PP | 4.16 (core) |

# Rulings

The release manager, 2026-10-17: "all rulings accepted". The Proposed column is
the ruling.

| Ref | L6's question | Proposed (ruled) |
|---|---|---|
| R1 | Where the payment code lives | **A payments extension**, `plugins/payments.pl`, a contract extension born off like the Odoo one, with **a provider seam**: one module per provider behind one interface. Stripe is the first and only provider in this filing. |
| R2 | Secrets | **Stored as the extension secrets are**: each in its own 0600 file, written alone through a 077 umask and renamed into place, in a 0700 directory, never listed, returned or logged, `has_secret` answering 1, 0 or null (fact 4). |
| R3 | Customer card data | **Stripe Checkout, hosted.** The visitor is sent to Stripe's page and back. No card number, expiry or security code ever reaches the site, in a request, a log or a record. Stripe Elements (fields on the site's own page) is not used. |
| R4 | Which Perl modules | **A small direct client**, over core and already-recommended modules: `Digest::SHA` for the webhook HMAC, `JSON::PP`, and the connector's `LWP::UserAgent` shape for the calls out, gated by `Lazysite::Egress`. No CPAN Stripe client: none is packaged for Debian (fact 10), and the site needs four calls and one signature check. |
| R5 | Odoo's own `payment_stripe` | **Lazysite takes the payment and hands the facts to Odoo through a named OOM operation**, so Odoo stays private. The trade-off is below. |

## R4 in detail: what "over `Lazysite::Egress`" means here

`Lazysite::Egress` decides *who may cause* a call and *whether a cap is
reached*; it sends nothing (fact 3). So the client is three parts:

- **the gate**: every call out asks `Egress::may_invoke` with the mode the
  caller *is* (`public` for a visitor starting a payment, `scheduled` for the
  hand-off job) and `Egress::within_caps` with counts from the payments record;
- **the transport**: an `LWP::UserAgent` built as the connector's is, with
  `max_redirect => 0`, a `max_size` cap and a timeout, to one destination the
  provider module declares (`https://api.stripe.com`), never configurable from a
  page or request; a test injects a transport instead (the test plan);
- **the signature check**, which needs no network: Stripe's `Stripe-Signature`
  header carries a timestamp `t` and one or more `v1` signatures; each `v1` is
  HMAC-SHA256, hex, of `"<t>.<raw body>"` under the endpoint's signing secret.
  The check compares with `Lazysite::Util::const_eq` against every `v1` (more
  than one is present while a secret is being rolled) and refuses a `t` outside
  a tolerance, default 300 seconds either way, configurable 60 to 600.

*The Stripe particulars in this filing (header format, endpoints, event names,
key prefixes, the 300-second tolerance Stripe's own libraries default to, the
retry on a non-2xx answer) are from Stripe's published API and were not
re-checked here, because this host has no network. S2 checks each against
Stripe's documentation before code is written, and the fake Stripe's fixtures
are taken from it.*

**No API version pin** *(design choice)*: the client reads only the fields
it needs and refuses, by name, an answer missing one, so a change to the account's
default version shows as a named refusal and never as a wrong amount.

## R5 in detail: the trade-off against Odoo's `payment_stripe`

| | Lazysite takes the payment (ruled) | Odoo's `payment_stripe` |
|---|---|---|
| Odoo on the public network | No. Odoo is reached only by OOM from the site's host | Yes: Stripe's webhook must reach Odoo's route |
| Who receives and verifies the webhook | Lazysite (S4) | Odoo |
| Where the attempt's record lives | Lazysite's payments record; Odoo gets the outcome | Odoo's `payment.transaction` |
| What lazysite must build and keep | The client, the webhook endpoint, idempotency, the record, the hand-off retry (S1-S7) | A start call through OOM and a return page |
| Odoo's own payment flow (transaction states, provider settings in Odoo) | Not used; what Odoo records is what A2 posts, to the owner's postings | Used as Odoo ships it |
| A second provider later | A second provider module behind the seam | Odoo's module for that provider, if one exists |

The cost of R5 is that lazysite owns code Odoo already has. The gain is the
plan's condition that Odoo stays private, and one place (the site) where a
visitor's payment, its CSRF, its caps and its audit are handled the way every
other public write is.

# The design

The choices below that the rulings do not settle are marked *(design choice)*.

## The shape

```
visitor ──POST start──▶ lazysite-pay.pl ──A1 (read)──▶ OOM ──▶ Odoo
                          │  amount from Odoo, never from the request
                          ├──create Checkout Session──▶ Stripe
visitor ◀──303 to Stripe's hosted page
visitor ──pays on Stripe──▶ Stripe
Stripe ──POST webhook (signed)──▶ lazysite-pay.pl ── verify, record once, 200
daemon job payments-handoff ──retrieve payment + fees──▶ Stripe
                            ──A2 (write, idempotent)──▶ OOM ──▶ Odoo posts
visitor ◀── return page shows the state from the record
```

## The extension and its configuration (S1)

`plugins/payments.pl`: a contract extension, born off, declaring
`owns.endpoints => ['lazysite-pay.pl']`, its config keys, and no `storage`
(as the Odoo extension, for the same reason: the store holds secrets and money
records that a site package must not carry). Config in `lazysite/payments.conf`
*(design choice)*:

| Key | Meaning | Default |
|---|---|---|
| `payments_provider` | the one provider in use | `stripe` |
| `payments_mode` | `test` or `live` | `test` |
| `payments_return_page` | the site page Stripe sends the visitor back to | `/payment` |
| `payments_signature_tolerance` | seconds, 60-600 | 300 |
| `payments_rate_per_visitor_hour` | payment starts per visitor key per hour | 10 |
| `payments_rate_per_hour` | payment starts per site per hour | 200 |
| `payments_order_binding` | the Odoo binding (type `odoo`) that answers A1 | none |
| `payments_handoff_binding` | the Odoo binding that runs A2 | none |
| `payments_keep_days` | how long attempt records are kept | 400 |

Configuring it, and setting its secrets, needs a new capability,
`manage_payments` *(design choice: where the money goes and who holds the keys
is authority of its own; the Odoo extension uses `manage_connectors` and planned
`manage_odoo` for the same reason)*. Operator-only by default.

## Secrets, and test against live (S0, S1)

Four secrets for Stripe, each its own file under `lazysite/payments/keys/`:
`stripe-test-secret.key`, `stripe-test-webhook.key`, `stripe-live-secret.key`,
`stripe-live-webhook.key`. **S0 moves the file mechanics of
`Lazysite::Odoo::Secret` into one shared module** (`Lazysite::SecretFile`:
`has`, `set`, `clear` over a directory and a name), used by the Odoo extension
unchanged in behaviour and by this one, so there is one copy of the 0600
discipline *(design choice: the pre-stable rule against debt; the second copy is
the alternative refused)*.

- `payments-status` (the configuration without any secret, `has_secret` per
  file three-state, the mode, the last webhook seen per mode),
  `payments-secret-set` (`mode`, `kind` = `secret`|`webhook`, `secret`),
  `payments-secret-clear`. POST-only, `manage_payments`, control API only. No
  MCP twin, as for the Odoo key: setting a credential is an operator act.
- **The key's prefix must match its slot** *(design choice)*: a `test` secret
  key must start `sk_test_` or `rk_test_`, a `live` one `sk_live_` or
  `rk_live_`, a webhook secret `whsec_`. A key in the wrong slot is refused by
  name at set time, and again at use, so a live key never runs in test mode
  and the reverse. A restricted key (`rk_`) is recommended in the docs, with the
  permissions the four calls need.
- **Switching `payments_mode`** changes which pair is read, and nothing else;
  attempts carry the mode they were made in, and a webhook is checked against
  the secret of the attempt's mode.
- A `live` mode on a site served over plain `http://` is refused, and the
  health check names it.

## The record (S3)

One record per **attempt** (a visitor pressing Pay once for one order), in
`lazysite/payments/attempts/<id>.json`, written under a lock *(design choice: a
file per attempt, as the Odoo plans are; the data extension's tables are the
alternative, refused because a payment record is engine state and not site
content)*.

| Field | Holds |
|---|---|
| `id` | 128 random bits, hex; the attempt's name everywhere, and Stripe's `client_reference_id`, `metadata.lazysite_payment` and `Idempotency-Key` on the create call |
| `provider`, `mode` | `stripe`, `test`\|`live` |
| `order_ref` | the Odoo order reference, as A1 answered it |
| `amount`, `currency` | integer minor units and the ISO code, **from A1, never from the request** |
| `actor` | `visitor:<hash>` or `account:<name>`, as the Odoo call record writes it |
| `session_id`, `payment_id` | the Checkout Session and the PaymentIntent ids |
| `state` | `started` → `open` → `paid` \| `processing` \| `failed` \| `expired`; `refused` when the start was refused before Stripe was called |
| `events` | each applied event: id, type, `created`, received-at |
| `fees` | from the job's retrieve: `fee`, `fee_currency`, `net`, the balance transaction id |
| `handoff` | `pending` \| `done` \| `failed`, attempts, the last refusal kind, what A2 answered |
| `flags` | `amount-mismatch`, `second-payment` (below) |

It holds **no card data** (none reaches the site) and no customer name, email
or address *(design choice: the customer's details are Odoo's partner, and
Stripe's own record is Stripe's)*.

**Idempotency is keyed on the provider's event id.** Applying an event begins
with an exclusive create (`O_CREAT|O_EXCL`) of
`lazysite/payments/events/stripe/<event id>`. The file system makes that atomic,
so two deliveries of one event, even at the same instant in two processes,
apply once: the second finds the marker, records `duplicate`, and answers 200.
The hand-off is idempotent a second time on Odoo's side, keyed on the provider
payment id (A2), so a retried hand-off cannot post twice either.

One fixed-field line per event and per call out in
`lazysite/payments/calls.jsonl` (`at id attempt actor ip provider mode kind
event_type phase outcome ms`, the sink refusing any other key, as
`Lazysite::Odoo::record_call` does), and one `payment` line per state change in
the shared audit trail. Never a secret, a signature, or the body of an event.

## Starting a payment for an Odoo quotation (S4, S5)

The page endpoint, `lazysite-pay.pl` *(design choice: its own endpoint, as
`lazysite-odoo.pl` is, so the webhook's unauthenticated door is not a branch of
an endpoint with a session-authenticated one)*:

`POST ?start=1 {order}` with the visitor token (or the session token for a
signed-in account), as the Odoo endpoint's POSTs are:

1. CSRF: the visitor-bound or session-bound token, refused as `csrf`.
2. Caps: per visitor key and per site, `Egress::within_caps`, `429` (`rate`).
3. **The order and the amount come from Odoo.** The endpoint runs the
   `payments_order_binding` (an `odoo` binding, A1) through
   `Lazysite::Odoo::call`. Which order a visitor may pay is the binding's: for a
   basket, the binding's `visitor_param` gives the visitor's own quotation and
   `order` is not needed; for an order reached by link (a quotation sent by
   email), the reference travels with the access token Odoo's portal gives
   that order, and A1 answers only when both match. A visitor can therefore
   pay only an order Odoo says is theirs. Anything else is `not-found`.
4. The answer must say the order is payable, with an amount above zero and a
   currency; otherwise `refused` with a code (below).
5. **One open attempt per order** *(design choice)*: an open attempt for the
   same order and amount is reused (the visitor is sent to the same Stripe
   page); for a changed amount the old session is expired at Stripe first.
6. The attempt is written (`started`), the Checkout Session is created
   (`mode=payment`, one line for the order total, `client_reference_id` and
   `metadata.lazysite_payment` = the attempt id, `success_url` and `cancel_url`
   = the return page with `?payment=<attempt id>`, `Idempotency-Key` = the
   attempt id), and the attempt becomes `open` with the session id.
7. The answer is `303` to the session's URL for a no-JS post, or
   `{ ok: 1, url }` for the browser helper. **The URL is the one Stripe
   returned, and its host must be one the provider module declares**
   (`checkout.stripe.com`); anything else is refused, so the endpoint can never
   be made to redirect a visitor to a host of the request's choosing.

**A binding or a form.** Both, over the same start call:

- the browser helper gains `data-ls-pay` (a button; the order ref from
  `data-ls-pay-order` when there is one), in the helper the Odoo extension
  already loads (`/assets/lazysite-odoo.js`);
- a native `:::form` posts to the endpoint's start route without JavaScript.
  The form handler's `_redirect_back` stays same-site only; the start route is
  the one place a visitor is sent off-site, and only to the provider's
  declared host (step 7).

**The return page shows the record, never the query.** `?payment=<attempt id>`
names the attempt (128 bits, unguessable); the page shows its state as a
**code**, with the wording owned by the page, in the SM1124 shape: `paid`,
`processing`, `cancelled`, `expired`, `failed`, `refused`, `unknown`. Stripe
sending the visitor to `success_url` proves nothing: until the webhook has
arrived the page says `processing` and the helper polls `GET ?status=<id>`.
A crafted `?outcome=` or any other text in the query is never printed.

## The webhook endpoint (S4)

`POST lazysite-pay.pl?webhook=stripe`: **public, with no session and no
CSRF token, authenticated by the signature alone.**

1. The raw body is read whole, byte for byte, before anything parses it, up to
   256 KB *(design choice)*; larger is `413`.
2. The provider module verifies `Stripe-Signature` against the webhook secret of
   each mode that has one (R4 detail). Missing, malformed, wrong or outside the
   tolerance: `400`, one line in the call record naming which, no audit line,
   nothing else written.
3. JSON decode; the event's `livemode` must match the mode whose secret
   verified it, else `400` and named.
4. The exclusive create of the event marker. Already there: `200`,
   `duplicate`, nothing applied.
5. The event's object must name an attempt this site made
   (`metadata.lazysite_payment` / `client_reference_id`) in that mode; an
   event for anything else is recorded `unknown-attempt` and answered `200`, so
   Stripe stops retrying a delivery that will never apply.
6. The events applied: `checkout.session.completed` with `payment_status=paid`
   → `paid`; with `unpaid` (a delayed method) → `processing`;
   `checkout.session.async_payment_succeeded` → `paid`;
   `checkout.session.async_payment_failed` → `failed`;
   `checkout.session.expired` → `expired`. Any other type is recorded `ignored`
   with its type and answered `200`; refunds and disputes arrive this way and
   are seen in the record (below).
7. A `paid` attempt whose session amount or currency differs from the attempt's
   is flagged `amount-mismatch`; a second attempt paid for an order that already
   has a paid attempt is flagged `second-payment`. Both are handed to Odoo as
   what happened (money was taken), with the flag, and shown to the operator.
8. `paid` sets the hand-off `pending`. The webhook answers `200` without calling
   Odoo: Stripe gets a fast answer, and Odoo being down cannot make Stripe
   resend.

Every write is under the attempt's lock, and the marker is created before the
attempt is changed, so a crash between the two leaves an event recorded and the
attempt unchanged; the hand-off job's retrieve (below) reconciles it.

## The hand-off to Odoo (S6)

A daemon engine job, `payments-handoff`, like `notify-outbox`, every 5 minutes
and on demand after a webhook *(design choice: outside the request, so the
webhook stays fast and a failure retries)*:

1. For each attempt with the hand-off `pending` or `failed` and due: retrieve
   the PaymentIntent from Stripe with its latest charge and balance transaction,
   in mode `scheduled`. The facts handed to Odoo come from **Stripe's API**, not
   from the webhook body, so a webhook is a trigger and never the evidence.
2. Run the `payments_handoff_binding` (A2) through `Lazysite::Odoo::call`,
   mode `scheduled`, `apply: immediate`, which SM747's Q1 ruling permits for a
   scheduled binding under the engine's controls.
3. Done: `handoff: done` with what A2 answered. Refused: the kind recorded,
   retried with back-off (5 min, 15 min, 1 h, then hourly) for 3 days
   *(design choice)*; after the first day the operator gets a notice (the bell,
   `Lazysite::Notify`) naming the attempt and the order. OOM answering
   `applied` (the payment already recorded) is `done`.

**What lazysite passes to A2**, all as plain values, none from a visitor:

| Parameter | Value |
|---|---|
| `order_ref` | the order reference |
| `amount`, `currency` | minor units and ISO code, as Stripe charged |
| `provider` | `stripe` |
| `provider_payment_id` | the PaymentIntent id (A2's idempotency key) |
| `provider_charge_id`, `checkout_session_id` | the charge and the session ids |
| `fee`, `fee_currency`, `net` | from the balance transaction, which can be in the account's settlement currency |
| `balance_transaction_id` | for payout reconciliation in Odoo |
| `paid_at` | when Stripe says the charge succeeded |
| `livemode` | so a test payment can never post into live books unseen |
| `flags` | `amount-mismatch`, `second-payment`, if any |
| `lazysite_payment_id` | the attempt id |

## Refunds

**Out of scope.** A refund is made in Stripe's dashboard; its event
(`charge.refunded`) is recorded `ignored` with its type, so the operator sees it
on the payments page against the attempt, and Odoo is told by hand. A later
filing can add an A3 (record a refund) and apply the event; the lazysite side is
small (one more event and one more hand-off), but what Odoo posts is the
owner's, as for payments, so it waits on O1.

## The operator's surface (S7)

- A Payments page (and `payments-list` / `payments-calls` actions,
  `manage_payments`): attempts by state, hand-off failures, flags, the last
  webhook seen per mode. No secret, no event body.
- The health check: the extension on with no webhook secret for the mode; live
  mode over plain http; no webhook seen in the mode for 7 days while attempts
  are opening; hand-offs failed for more than a day.
- A docs page, `starter/docs/payments.md`: setting up the Stripe account's
  webhook endpoint (the URL, the four event types), the restricted key's
  permissions, test mode first, and the two Odoo bindings.

# The asks of OOM

To file to OOM's inbox with this plan *(the names are OOM's to choose)*:

| Ref | Ask | Needed by |
|---|---|---|
| A1 | **A read operation: is this order payable, and for how much.** In: an order reference with the order's portal access token, or the visitor key a basket binding passes. Out: the reference, the amount due in minor units, the currency, the state, and whether it can be paid now. It answers nothing for a reference and token that do not match. | S5 |
| A2 | **A write operation: record a provider payment against an order**, with the parameters in *The hand-off to Odoo*. Idempotent on (`provider`, `provider_payment_id`): a second call answers `applied` and posts nothing. What it posts (the payment, the fee, the clearing account, the reconciliation with the invoice) is the owner's postings (O1), which OOM builds. Its plan is applied unattended by a scheduled binding. | S6 |

Both depend on the survey OOM's note already plans (`payment`,
`payment_stripe` as models, reconciliation of a payout).

# Slices

| Ref | Slice | Size | Depends on |
|---|---|---|---|
| S0 | `Lazysite::SecretFile`: the 0600 file mechanics out of `Lazysite::Odoo::Secret`, which uses it with no change in behaviour (t/unit/odoo/06 unchanged and green) | S | - |
| S1 | The extension: `plugins/payments.pl`, its config, `manage_payments`, the four secrets with prefix checks, `payments-status` / `-secret-set` / `-secret-clear` | M | S0 |
| S2 | The provider seam and `Lazysite::Payments::Stripe`: create session, expire session, retrieve payment with fees, verify a webhook; the transport injected; the boundary lint (no Stripe name outside the provider module) | M | S1 |
| S3 | The record: attempts, the event markers, the state machine, the call record, the audit lines, pruning | M | S1 |
| S4 | `lazysite-pay.pl`: the webhook route, the start route (with a fixed order for now), the status route, the return-page codes | M | S2, S3 |
| S5 | Starting from an Odoo quotation: the order binding (A1), the amount from Odoo, one open attempt per order, `data-ls-pay`, the `:::form` path | M | S4, A1 |
| S6 | The hand-off: the `payments-handoff` job, the retrieve, A2 through `Lazysite::Odoo::call`, retries and the notice | M | S3, S2, A2 |
| S7 | The Payments page, the health checks, `starter/docs/payments.md`, the CHANGELOG entry | S | S4, S5, S6 |

Overall: L. S0 to S4 can be built and tested now with the fake Stripe; S5 and S6
wait on A1 and A2 for their real bindings and are testable against OOM's own
test double meanwhile.

# Test plan

No test reaches a network. **The fake Stripe** is a transport injected into
`Lazysite::Payments::Stripe` (as OOM's `Context` takes an injected transport for
the Odoo tests): it answers create, expire and retrieve from fixtures, records
every request it was sent (path, form fields, headers), and can be told to fail,
time out, redirect or answer a body missing a field. **Webhooks are generated in
the test**: the test builds an event JSON, takes a timestamp, computes
`hmac_sha256_hex("$t.$body", $whsec)` with `Digest::SHA`, and posts the body
with `Stripe-Signature: t=$t,v1=$sig` to the endpoint run as a CGI with the raw
body on STDIN.

| Ref | Case | Expect |
|---|---|---|
| T1 | A signed `checkout.session.completed`, paid | `200`; attempt `paid`; hand-off `pending`; one event marker; one audit line |
| T2 | The same event delivered twice, then twice at once from two forked processes | One application; the others `duplicate`, `200` |
| T3 | One byte of the body changed after signing | `400`; nothing written but the call-record line |
| T4 | Signed with another secret; no header; a malformed header | `400`, each named |
| T5 | `t` 301 s old, and 301 s in the future; tolerance set to 600 then passes | `400`, then `200` |
| T6 | Two `v1` values, only the second valid (a secret being rolled) | `200` |
| T7 | A test-mode event against a live attempt, and `livemode` disagreeing with the verifying secret | `400`, named |
| T8 | An event for a session this site did not make; an unhandled type; `charge.refunded` | `200`, recorded `unknown-attempt` / `ignored` with the type |
| T9 | `unpaid` then `async_payment_succeeded`; `async_payment_failed`; `expired` | `processing` → `paid`; `failed`; `expired` |
| T10 | A paid amount differing from the attempt; a second paid attempt for one order | Flags `amount-mismatch`, `second-payment`, handed to Odoo with them |
| T11 | Start: the request sends an `amount` | Ignored; the session's amount is A1's (the fake Stripe's recorded request shows it) |
| T12 | Start: no token, a stale token, another visitor's token | `403` (`csrf`); Stripe never called |
| T13 | Start: over each cap; a cap record that cannot be read | `429`; refused |
| T14 | Start: an order the A1 binding does not answer for this visitor | `404` (`not-found`); Stripe never called |
| T15 | Start twice for one order, same amount, then a changed amount | One session reused; then the old one expired and a new one made |
| T16 | Stripe answering a session URL on another host | Refused; no redirect |
| T17 | A secret key in the wrong slot (`sk_live_` in test, `sk_test_` in live, a non-`whsec_` webhook secret) | Refused at set and at use |
| T18 | Outcome 4's inspection, as SM747's: after a full run, each secret is in its file and in no other file under the site, no response, no log line and no record | Holds |
| T19 | Hand-off: A2 refused, then accepted; A2 answering `applied` | Retried with back-off, then `done`; `applied` is `done`; one post |
| T20 | Hand-off: the retrieve's fee in another currency | `fee_currency` passed as Stripe gave it |
| T21 | Return page: `?payment=` unknown, and a crafted `?outcome=` text | `unknown`; the text is never printed |
| T22 | A crash between the event marker and the attempt write (simulated) | The job's retrieve brings the attempt to `paid` |
| T23 | The boundary lint: no Stripe endpoint, field or event name outside `Lazysite::Payments::Stripe` and its tests | Passes; and fails when one is planted |

Each guard is broken on purpose once and its test seen red, with the backup
under `tmp/sab-bak/sm1158/`, as SM747's slices were. A proof against Stripe's
own test mode (a real Checkout with a test card, a real signed webhook) is an
edge test, run by the operator on edge with test keys, after S6.

# Questions still open

Only what cannot be decided without the owner.

| Ref | Question | Blocks |
|---|---|---|
| O1 | **The account postings**: what Odoo records for a paid order, the Stripe fee, the clearing account between the charge and the payout, and how a payout is reconciled against the invoices (the owner said they will specify these) | A2, S6's real binding, refunds |
| O2 | **When the quotation is confirmed against the payment.** Before (stock is reserved at once, and must be released when the attempt expires or fails) or after the webhook (stock can go between the payment and the confirmation, and a paid order then needs a refund) | A1's "payable", A2, S5 |
| O3 | **Currencies**: which the shop charges in, and whether the Stripe account settles in another (the fee and net then arrive in the settlement currency) | A2's postings |
| O4 | **What Stripe collects from the customer** on its hosted page (email, billing address), given the customer is already an Odoo partner: personal data held by Stripe as well as Odoo | S5's session fields |
| O5 | **A paid order Odoo refuses** at hand-off (the quotation changed, stock gone under O2's "after"): refunded by hand from Stripe's dashboard (the plan, refunds being out of scope), or does it need a refund path now | the refunds scope |
