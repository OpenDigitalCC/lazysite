---
title: The Odoo extension
subtitle: Pages, forms, the schedule and agents run named Odoo operations through a connection user whose rights are set in Odoo.
register:
  - sitemap.xml
---

## Overview

The Odoo extension lets a site run **named operations** against one Odoo
instance. An operation - list products, add a line to a basket - comes from an
operation pack in OOM (`libodoo-oom-perl`). Lazysite names the operation, binds
its parameters, renders the report it returns, and presents a plan when the
operation changes data. Model names, field names and Odoo's call shapes stay in
the pack; lazysite's code holds none of them.

Every call runs through one function in the engine, which asks, in order:

1. may this caller run this binding here - the mode, the callers, the domain;
2. is the extension enabled;
3. is OOM installed and new enough;
4. is the connection configured;
5. is the connection user's key set;
6. does the operation exist, and does the binding fit what it declares;
7. are the parameters the request sent ones the binding takes, of the declared
   type;
8. is the call within the binding's rate caps.

Only then is Odoo called. Every outcome, including every refusal, is one line
in the call record.

## What it needs

- **OOM 0.03 or newer**, installed as the `libodoo-oom-perl` package (the Perl
  module `Odoo::Ops`). With OOM missing or older, every call is refused with a
  message naming the package and the version found; nothing is sent.
- **The extension enabled** on the Extensions page. It is installed disabled.
  While it is disabled the page endpoint answers `403` (`disabled`) and no
  binding runs. Its configuration can be edited while it is disabled.
- **The Status button** on the Extensions page reports whether OOM is present
  and whether the connection is configured. It changes nothing and never shows
  the key.

## The connection

One connection per site, in `lazysite/odoo.conf`, edited on the Extensions
page:

`odoo_url`
: The Odoo address. `https://` to any host. Plain `http://` only to this host
  (`localhost`, a `127.` address or `[::1]`). Plain `http://` to a private (RFC1918)
  address is refused; reach an internal Odoo over `https://` to its private
  name. A user name or password in the URL is refused.

`odoo_db`
: The database name on that instance.

`odoo_login`
: The **connection user**: a site-level Odoo account. Its rights are set in
  Odoo, by whoever administers Odoo. Lazysite grants it nothing and narrows
  nothing Odoo allows it.

`odoo_ca_file`
: Optional. The full path of a PEM file holding the certificate authority that
  signed your Odoo's certificate, for an Odoo behind a private authority - the usual
  case for an internal Odoo reached over `https://` to its private name. It must
  be a file this process can read, or the connection is refused by name. It is
  the CA bundle for the connection to Odoo only: lazysite hands it to OOM for the
  clients it builds for Odoo, and sets no variable in the server's environment, so
  every other connection the server makes keeps the system certificate store.
  Verification stays on.

`odoo_identity_ttl`
: Seconds a page may show who a signed-in person is in Odoo before it is
  asked of Odoo again. 60 to 86400, default 900. Presentation only.

`odoo_remember_device`
: Off by default. On, a person whose Odoo account has two-factor authentication is
  offered Odoo's own "don't ask again on this device" at the code step, over
  `https://` only. Odoo issues the device value and decides how long it is
  trusted; the browser keeps it in one cookie for this site (HttpOnly, Secure,
  SameSite=Strict) and lazysite stores nothing. Leave it off where a browser is
  shared: whoever is signed in is responsible for that device. Needs OOM 0.27.

`odoo_timeout`
: Seconds per call. Default 30. A call is made once; a failed call is not
  retried.

`odoo_max_kb`
: The largest answer accepted, in KB. Default 2048. A larger answer is refused
  by name.

`odoo_allow_writes`
: Off by default. While off, a write operation can produce a plan and never
  applies one (`read-only`).

`odoo_packs`
: Perl namespaces of operation packs installed beyond OOM's own, comma
  separated.

## The connection user's key

The connection user signs in with an **API key** issued in Odoo, never a
password. The key is set and cleared over the control API or MCP, with
`manage_connectors`:

`odoo-secret-set` / `odoo_secret_set`
: Body `secret`. One line of printable characters, no spaces, at most 512.

`odoo-secret-clear` / `odoo_secret_clear`
: Removes it.

`odoo-status` / `odoo_status`
: The connection without the key, `has_secret`, OOM's state and the installed
  operations.

The key is written alone in its own file under `lazysite/odoo/keys/`, created
`0600` in a `0700` directory, and OOM refuses to read a key file group or
others can read. No action, tool or page returns it, and it is not logged.
`has_secret` is `1` (set), `0` (not set) or `null` - the file exists and this
process cannot read it, which is reported rather than treated as unset.

## Bindings

A **binding** is a handler of type `odoo` (*Run an Odoo operation* on the
Handlers page), configured with `manage_connectors`. It names one operation and
says what a request may set and who may cause it:

`operation`
: The OOM operation, such as `pack.action`. Saving checks the binding against
  the operation's own declaration when OOM can be asked.

`params`
: `field=parameter`, comma separated - **the only values a request supplies**.
  Each goes into a parameter the operation declares as a plain value (`str`,
  `int` or `bool`), is checked against that type, is at most 1,000 characters
  and carries no control characters. The page endpoint refuses a field the
  binding does not map; a form drops it.

`fixed`
: `parameter=value`, comma separated. Set by the operator; nothing a request
  sends overrides one. A `json` or `list` parameter can only be fixed. A `path`
  parameter cannot be set by a binding at all.

`visitor_param`
: The parameter that receives the visitor's key (see *The anonymous write
  path*). The server supplies it; a request cannot.

`modes`
: Who may run it, comma separated: `authenticated` (a signed-in account in
  `callers`, or one holding `manage_connectors`), `public` (anyone - a page, the
  page endpoint, a form), `scheduled` (the schedule). Default
  `authenticated`.

`callers`
: Groups whose members may run it in `authenticated` mode.

`apply`
: `confirm` (default): a write operation returns a plan, which the account or
  visitor that made it applies with a confirm. `immediate`: the write applies
  in the same request.

`rate_per_visitor_hour`, `rate_per_hour`
: The rate caps. Defaults 20 and 200.

`domain`
: Optional. A binding with a `domain:` runs only for requests on that domain;
  one without runs for every domain the instance serves (see *Domains*).

A parameter has exactly one source: a name in two of `params`, `fixed` and
`visitor_param` is refused at save.

## Where a binding runs

The page endpoint, `/cgi-bin/lazysite-odoo.pl`
: A page's own JavaScript. `GET ?csrf=1` returns the tokens for this browser
  (minting the visitor cookie if there is none). `GET ?binding=ID&field=value`
  runs a binding whose operation only reads; a writing binding sent as a `GET`
  is refused (`405`). `POST {binding, params, visitor_token}` runs a binding;
  `POST {plan, confirm: true, visitor_token}` applies a plan this caller made.
  A signed-in caller sends the session token (`X-CSRF-Token` or `token`)
  instead of `visitor_token`. Bodies over 64 KB are refused.

  `GET ?csrf=1` also says who is signed in to Odoo. For a person with an Odoo
  session and a current identity cookie the answer carries
  `identity: {name}` - the display name, and nothing else
  about the person - so a page need not call Odoo to show a name. It asks Odoo
  nothing: it reads the signed identity cookie the endpoint already verifies, which
  stays `HttpOnly`. When that cookie has ended (after `odoo_identity_ttl`) there is
  no `identity` until the next call that reaches Odoo freshens it. Presentation
  only: nothing is permitted by it.

  `POST {calls: [{binding, params}, ...]}` runs several calls in one request, so a
  page with several reads pays the endpoint's start-up once. At most **10** calls
  (`invalid` beyond that, before any call is made). The answer is
  `{ok: 1, results: [...]}`, one result per call in the order sent, each the answer
  that call would have had alone plus its own `status`. Each call is checked,
  authorised, rate-counted, recorded and audited exactly as a single call: a call
  that fails does not stop the others, a write plans or applies as its binding says
  (`{plan, confirm: true}` is a call too), and the request's one token is checked
  for each call against what that call's binding needs. A call cannot carry a token
  of its own, and a sign-in or sign-out is not a batch call. If Odoo ends the
  person's session during a batch, the calls after it do not run on it.

A page binding, `odoo:ID`
: In `tt_page_var`, for example `stock: odoo:shop-list`, puts the report of a
  reading binding on the page. It runs as `public` with no request input. It
  never runs an operation that writes, never runs a binding with a
  `visitor_param`, and every value in the report is HTML-escaped as a `db:`
  value is. When the operation returns `rows` beside `fields` (descriptors with
  a portable type), the variable carries `fields` (the ones lazysite can draw),
  `refused` (each field it could not, and why) and `rows` cut to the drawn
  columns; a field with no portable type is never guessed at.

A form
: A form bound to the binding runs it as `public`, with the form's fields as
  the request. A binding with a `visitor_param`, or a write with
  `apply: confirm`, is refused for a form. A change that was applied in Odoo but
  whose checks afterwards reported `apply-incomplete` was made, so the form is
  delivered and the visitor is shown the ordinary acknowledgement; the warning is
  in the call record (kind `apply-incomplete`), in the delivery's audit line and in
  the event log, for the operator. A change that failed, or was not attempted, is
  not a delivery and the form says so.

The schedule
: A schedule entry runs it as `scheduled`. The same two refusals apply.

The control API and MCP
: `odoo-bindings` / `odoo_bindings` lists the bindings this caller may run,
  with the fields each takes. `odoo-run` / `odoo_run` runs one, and
  `odoo-confirm` / `odoo_confirm` applies a plan the caller made. A reading
  operation that returns descriptors also answers `fields` and `refused` beside
  `report`. The caller is
  `authenticated`, under the binding's `callers`; it is never a visitor, so a
  binding with a `visitor_param` is not listed or run here.

## A person's own Odoo account (`credential: session`)

A binding with `credential: session` runs as the **person signed in to Odoo
through the page**, with their own Odoo rights, instead of as the connection user.
Odoo decides what that person may do; lazysite adds nothing to it and narrows
nothing. It is what an app where each person works as themselves is built on.

What the binding is, as saved:

- authenticated mode only: `public` and `scheduled` in `modes` are refused, since
  neither has such a person;
- no `callers` and no `visitor_param` (Odoo decides who may, and the call runs as
  a person, not a visitor key);
- the connection user's API key is not read for the call (the connection itself -
  URL, database, login - must still be configured). A call from someone with no
  Odoo session is refused and never run as the connection user, whose account is
  likely wider than the person's; a read says `signin-required` (`401`).

How a person signs in, on the page endpoint:

`POST {signin: true, login, password, visitor_token}`
: The password goes to Odoo through OOM once and nowhere else: not a log, a record,
  an error or a file. Needs the visitor token (bound to the visitor cookie, which
  `SameSite=Strict` keeps off a cross-site request). Attempts are counted by the
  site's own sign-in limiter, five in five minutes per address and per login
  (`rate`, `429`). A refused sign-in is `signin-refused` (`401`); an account with
  two-factor authentication, which Odoo accepts and opens no session for, is
  `two-factor` (`403`) - it cannot sign in with a password alone here. The answer
  is `{ok: 1, signed_in: 1, identity: {name, login, lang, tz}}` and two cookies.

`POST {signout: true, visitor_token}`
: Ends the session at Odoo and clears both cookies. A person with no session is told
  `ok` all the same.

The two cookies:

`lzs_odoo_session`
: The credential. The Odoo session id, signed with the extension's own secret,
  dated inside the signature (twelve hours, whatever Odoo says), `HttpOnly`,
  `SameSite=Strict`, `Secure` over HTTPS, and scoped to the path of the endpoint so
  nothing else on the site receives it. The id is in no response body, log or
  record; a record names a hash of it.

`lzs_odoo_identity`
: Who the person is, for a page to show: name, language, time zone, companies
  and groups. Signed, `HttpOnly`, `SameSite=Lax`, valid for `odoo_identity_ttl`, and
  refreshed from the session by the next call that reaches Odoo once it has ended.
  Presentation only: nothing in the engine reads it to permit anything.

A call, once signed in:

- a `GET ?binding=ID&field=value` for a reading binding, or a `POST` for one that
  writes, carries the **visitor token** (not the site's session token: a person
  signed in to Odoo may have no account on this site);
- a write with `apply: confirm` makes a plan owned by that session, and only that
  session can confirm it, within the hour;
- the call record's actor is `session:` and a hash, and the rate caps count per
  session;
- when Odoo says the session has ended, both cookies are cleared, the call is
  refused `signin-required` (`401`) and nothing is run in its place. The browser
  helper then asks the person to sign in and sends the call once more.

Where it does not run: a page binding (`odoo:ID`), a form and the schedule refuse a
session binding by name, and the control API and MCP neither list nor run one,
because none of them carries a person's Odoo sign-in.

An example, with a generic pack: an operation `pack.my_orders` that lists the
orders of whoever asks, run as that person.

```
Handler (type: odoo)
  id: my-orders
  operation: pack.my_orders
  credential: session
  modes: authenticated
```

```
<p>Signed in as <span data-ls-odoo-name></span></p>
<button data-ls-odoo-signin>Sign in to Odoo</button>
<button data-ls-odoo-signout>Sign out</button>
<ul data-ls-odoo="my-orders" data-ls-odoo-limit="20">
  <template><li><span data-ls-field="name"></span></li></template>
  <p data-ls-empty>No orders.</p>
</ul>
```

The region reads `my-orders` as the signed-in person; with no sign-in it asks for
one and sends the read again once.

## The anonymous write path

A binding with `public` in `modes`, a writing operation and `apply: immediate`
lets a visitor who is not signed in change data in Odoo - for example, add a
line to a basket that Odoo holds as a quotation. What it can change is bounded
by the connection user's rights in Odoo and by the operation's declared scope,
which OOM enforces before any call leaves. The engine adds:

- **The visitor's key.** 256 random bits minted by the server and carried in
  the cookie `lzs_odoo_visitor`, signed with the extension's own secret
  (`lazysite/odoo/visitor.secret`, `0600`). The cookie is `HttpOnly`,
  `SameSite=Strict`, `Secure` over HTTPS, and lasts 30 days. A key the server
  did not mint is treated as no visitor. The key reaches an operation only
  through `visitor_param`, so a visitor reaches only records keyed by their
  own key.
- **A token on every state-changing POST.** The visitor token is an HMAC of
  the visitor's key; a POST needs both the cookie and the token. A cross-site
  POST arrives without the cookie.
- **Plans belong to whoever made them.** A plan's id is 128 random bits. Only
  the account or visitor that made it can apply it, within an hour, through
  the binding as it stands then. Anyone else is told the plan was not found.
- **Rate caps.** Per visitor (or account) per hour, `rate_per_visitor_hour`,
  and per binding per hour, `rate_per_hour`. An attempt counts when it is
  admitted, whether Odoo then accepts it or not. When the count cannot be
  read, the call is refused. Over a cap the answer is `429` (`rate`).
- **The record names a hash of the key**, never the key.

## A grant's own Odoo account

By default an MCP grant runs bindings as the connection user. An operator can
give a grant its own Odoo account: `odoo-secret-set` with `grant` (the lazysite
account), `login` (the Odoo login) and `secret` (that login's API key). The key
is stored as the connection user's is, in its own `0600` file named from a hash
of the account. `odoo-status` lists each grant with its login and
`has_secret`; `odoo-secret-clear` with `grant` removes it.

When the grant map cannot be read, the grant's calls are refused rather than
run as the connection user. The control API always runs as the connection
user.

## The browser helper

`/assets/lazysite-odoo.js` is the one module a page uses to talk to the endpoint. It
is added to a page whose markup carries `data-ls-odoo`, `data-ls-odoo-signin` or
`data-ls-odoo-signout`, and to no other.

```
<div data-ls-odoo="shop-list" data-ls-odoo-limit="10">
  <template><li><span data-ls-field="name"></span></li></template>
  <p data-ls-empty>Nothing to show yet.</p>
</div>
<button data-ls-odoo-signin>Sign in to Odoo</button>
<button data-ls-odoo-signout>Sign out</button>
```

`<span data-ls-odoo-name>` is filled, as text, with the signed-in person's display
name when the page loads, from the `?csrf=1` answer above - no Odoo call. A page with
no such element asks for nothing. `LazysiteOdoo.who()` resolves `{name}` or
`null`, and `LazysiteOdoo.batch([{binding, params}, ...])` sends several calls as one
request: a call refused for a stale token, or for want of a sign-in, is sent again
once - those calls only - and the person is asked once.

A region runs the binding with the request fields named by its `data-ls-odoo-<name>`
attributes and fills its `<template>` from the rows, as text, for the fields the server
drew. The module fetches the tokens, sends a stale one again once, and when the
endpoint says to sign in, asks the person - and sends the call again once. The
password goes in the body of one request to the page's own endpoint and the box is
cleared before the answer arrives; nothing is stored in the browser.

**Two-factor accounts (OOM 0.27 or later).** When the Odoo account has two-factor
authentication, the password is answered with a second step and the dialog asks for
the 6-digit code from the person's authenticator app; the code is handled like the
password and sent in one request of its own. A wrong code says so and the person
may try again, within Odoo's own limit on tries. The half-open sign-in is carried
between the two requests in a signed, HttpOnly cookie that is good for five
minutes and is not a session. With an older OOM such an account is refused by name
(`two-factor`).

## Domains

On an instance serving several domains, a binding with `domain:` runs:

- for the page endpoint, a page binding and a form, only when the request's
  host is that domain;
- for the control API and MCP, only for a caller that reaches that domain - an
  unconfined operator, or a grant confined to that domain;
- for the schedule, always.

Anywhere else the call is refused as `wrong-domain` (`403`) and recorded, and
`odoo-bindings` does not list it. A binding without `domain:` runs everywhere.

## The call record

One line per call in `lazysite/odoo/calls.jsonl`, with fixed fields only: when,
the call id, the actor, the visitor hash, the IP, the Odoo login, the binding,
the operation, the mode, the phase (`run`, `plan`, `apply`), the outcome, the
refusal kind and the duration. Never a parameter value, a report or a key.
Kept 90 days. `odoo-calls` / `odoo_calls` (`manage_connectors`) reads it,
optionally for one `binding`. Each call is also one `odoo-call` line in the
audit trail.

## Refusals

A refusal is `{ ok: 0, kind, error }`. Odoo's own fault text is logged and
never returned. The kinds a caller meets most:

| Kind | Status | Means |
| --- | --- | --- |
| `mode` | 403 | this caller may not run this binding in this mode |
| `wrong-domain` | 403 | the binding belongs to another domain |
| `disabled` | 403 | the extension is disabled |
| `csrf` | 403 | the token is missing, stale, or not this visitor's |
| `read-only` | 403 | `odoo_allow_writes` is off |
| `two-factor` | 403 | the account has two-factor authentication and the installed OOM cannot take the code (before 0.27) |
| `signin-refused`, `signin-required` | 401 | the password was refused, or the sign-in (or its pending code step) has ended: sign in again |
| `second-factor` | 401 | Odoo did not accept the code; the person may try again |
| `invalid` | 400 | a parameter is unmapped, of the wrong type, or missing |
| `rate` | 429 | a rate cap is reached |
| `not-found` | 404 | no such binding, or no such plan for this caller |
| `stale`, `edited`, `applied` | 409 | the plan no longer fits Odoo, or was already applied |
| `expired` | 410 | the plan is older than an hour |
| `unavailable`, `config`, `no-key` | 503 | OOM is missing or too old, the connection is not configured, or the key is not set |

## Not available yet

- The parameter form (`x.form`) on the page binding.
