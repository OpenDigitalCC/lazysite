---
title: Connectors
subtitle: A reusable, credentialed destination that forms, callers and jobs send site data through - and where what comes back is kept.
register:
  - sitemap.xml
---

## Overview

A **connector** is a place site data may be sent: a URL, the header its
secret travels in, the modes it permits, the groups that may call it, a rate
cap, and optionally the data table its answers land in. Several forms,
callers and jobs send through one connector, so the credential is held once,
engine-side, and never in a page or a form.

The engine could already POST a form to a URL (the `webhook` handler). A
connector adds three things: **who may cause the call** is decided before
anything is sent; **how often** is capped per connector; and **the answer is
kept** in a table a page can render from.

## Who may cause a call

The risk of an outbound call is not what the remote does. It is who can make
it happen. A connector declares which of three modes it permits, and a call
in any other mode is refused by name:

`authenticated`
: A logged-in caller, over the control API (`connector-call`). The caller
  must be in one of the groups the connector names as `callers`, or hold
  `manage_connectors`. Attributable to a person, rate-limited, revocable by
  removing a grant. **On by default.**

`public`
: A public form may trigger it, through the `connector` form handler.
  **Off by default** - the connector must say `public: 1` deliberately. The
  engine bounds who and how often; **you bound what is sent**: give a public
  form fixed choices (`select:A,B,C`), not a free textbox, when the field
  reaches a remote service. A free textbox on a public form is whatever a
  visitor types, sent outward under your credential.

`scheduled`
: The timer calls it, with no request involved at all. Declared now, invoked
  in a later release.

## Defining a connector

Over the control API, with `manage_connectors`:

```
POST action=connector-save
{ "id": "crm",
  "connector": {
    "name": "CRM intake",
    "url": "https://crm.example/api/leads",
    "method": "POST",
    "secret_header": "Authorization",
    "secret_prefix": "Bearer ",
    "modes": { "authenticated": 1, "public": 0 },
    "callers": ["sales"],
    "rate_per_hour": 60,
    "timeout": 10,
    "answer_table": "crm_answers",
    "data_class": "form"
  } }

POST action=connector-secret-set
{ "id": "crm", "secret": "..." }
```

The secret is stored apart from the definition, `0600`, and never listed or
returned; `connector-list` says only whether one is set: `has_secret` is
`1`, `0`, or `null` when the secret store exists and the request path
cannot open it (`secrets_readable: 0`, with a `warning` naming the file
and the unix user). Null is not "not set" - the credential is still there;
a call through that connector is refused rather than sent without it, and
no secret is written over a store that could not be read. Only `https://`
destinations are accepted (plain `http://` to `127.0.0.1` or `localhost`,
for a stand-in). The payload is a flat set of text fields - form fields or a
table row - never a file.

## Calling one

```
POST action=connector-call
{ "id": "crm", "payload": { "name": "...", "email": "...", "interest": "batch" } }
```

The answer comes back to the caller (`state`, `http`, `answer`) and, when the
connector names an `answer_table`, is inserted there as a row - columns
`connector`, `call_id`, `mode`, `actor`, `at`, `state`, `http`, `answer` -
which a page then reads like any other table. A missing table is reported on
the call, not skipped.

A public form sends through the same connector by binding the `connector`
handler - added on the Form Handler plugin's page (choose "Connector",
name the connector id) or written into `lazysite/forms/handlers.conf`:

```
handlers:
  - id: crm
    type: connector
    connector: crm
```

A connector handler that names no connector is refused when saved, by
name, rather than stored unable to send.

## What is recorded

Every call is one line in `lazysite/connectors/calls.jsonl` and one audit
event: the connector, the trigger, the mode, the class of data, who caused
it, the outcome and how long it took. **Never the payload, never the
answer.** `connector-calls` lists the record, filtered by connector or by
state; the `connectors-sweep` job expires it after thirty days and counts the
calls that never answered.

A call has one of four outcomes, and none of them is "waiting": `answered`,
`failed` (the remote said no), `unanswered` (it never replied within the
timeout), `refused` (the mode, the callers, the payload's shape, the rate
cap, or a store the request path could not read said no before anything
was sent). Every refusal is a row in the connector's own record, carrying
`why` and the actor - so the account outside the callers that tried the
connector is there by name - and refusals do not count against the rate
cap. An unanswered call's `answer` is the transport's one-line reason,
never a library path.

## Capability

`manage_connectors`
: Configure connectors: create, change, delete, set secrets, read the call
  record, and call any connector. It is authority over **where site data
  goes** - a conferral like `manage_data`, not part of `manage_config`.
  Calling a connector as an ordinary logged-in user needs no capability:
  the connector's own `callers` list decides.
