---
id: SM1376
title: "SM1376: write-back to a source's API"
subtitle: "A site whose facts live on a partner platform sends changes there instead of keeping its own copy: a native form posts to the partner and shows its answer, an owner's edit to a sourced column goes to the source, and a failed post is said and logged with nothing kept in its place."
brand: plain
standard-margins: true
status: candidate
raised: 2026-11-06
raised-by: "release manager (ruling 129)"
area: data
status-note: "Filed 2026-11-06, ruling 129. Candidate; target 0.17.0. Generic, in core, built on the connector handler (SM842) and SM1364's sources. Supersedes SM1364's 'Writing back: none'. Questions for ruling below."
---

# The need

Where a partner platform holds a fact (a booking, a business's details, an
order), [[SM1364]] has the site read it from there rather than keep a second
copy. The other direction is the same rule: a change the site's visitors or
owner make goes to the partner platform, and the site then shows what the
platform holds. Three needs:

a. **A form posts to the partner and shows its answer.** A native form posts its
   fields as JSON to a configured endpoint, with the credential held on the
   server. The visitor sees the partner's answer (confirmed, refused, and the
   reason) in the site's own layout, never in an iframe.
b. **An owner's edit to a sourced column goes to the source.** Where a table's
   column comes from a source, an edit to it is sent to the source's API rather
   than stored, and the site then shows the source's value.
c. **A failed post is said, logged, and not replaced.** The visitor is told the
   post failed, the failure is logged, and nothing is kept locally in its place.

Generic and in core: nothing here names a partner. An app supplies the
endpoint, the credential and the field mapping as configuration.

# What exists

| Need | What the engine has today |
| --- | --- |
| a: post as JSON | The `connector` handler (SM842) sends a form's visible fields through `Lazysite::Manager::Connectors::call`, as a JSON body (`format: json`) to the connector's configured URL. |
| a: credential on the server | The connector's secret lives in the reserved tree and is added as a header (`secret_header`, `secret_prefix`); no page or visitor sees it. A connector does not follow redirects, so the credential cannot travel elsewhere (SM790). |
| a: who may cause the call | The connector's `modes` (a form is public invocation), its rate cap, and one call record per call (SM579). |
| a: the partner's answer | `Connectors::call` returns `answer` (the decoded JSON body, capped) and can keep it in an `answer_table` row. |
| a: what the visitor sees | `_to_connector` in `Lazysite::Handlers` returns only `call_id`; the form handler answers with a fixed sentence, "received and sent for processing" (`ok-processing`). The answer is dropped. |
| a: in the site's layout | A native form's answer is either JSON to the shipped form script or a redirect back to the page carrying an outcome CODE, never a sentence (SM1124 F-3). |
| b: sourced columns | None. SM1364 (candidate) proposes sources with the mapped columns read-only. |
| b: one write path | Every door that writes a row (control API, MCP, `lazysite-data.pl`, a `table` handler) goes through `Lazysite::Data::Tables`, which applies one set of type checks. |
| c: a failed call | The call is recorded and logged with its state (`failed`, `unanswered`, `refused`). If the connector was the form's only target, the visitor gets the generic `undelivered` refusal. If another target (a file or table handler) accepted it, the submission is stored locally and the visitor is thanked. |
| precedent | The engine's own ERP integration shows a visitor the remote's refusal in its own words when the remote refused the data, and a plain sentence otherwise (SM1374, pending in 0.16.6). |

# What is missing

- **a:** carrying the connector's `answer` back through `deliver` to the form
  handler, a declared mapping from the partner's answer to an outcome (confirmed
  or refused) and a reason the visitor may see, and a way to show that reason on
  the page without putting free text in the redirect.
- **b:** a column that names its source and the source's write call; routing an
  edit on that column, on every door, to the connector instead of the store; and
  re-reading the source's value after the write.
- **c:** a form whose connector is the system of record must not fall back to a
  local copy. Today a second target makes a failed post look like a success.
  The refusal must say the partner did not take it, not that the form is off.

# Questions for ruling

1. **Where the partner's answer is shown.** A JSON reply to the shipped form
   script can carry the reason. A form posted without script redirects back with
   a code. Should the reason ride on a short-lived server-side result the page
   reads by token, or should a form bound to a partner need the script?
2. **How the answer is read.** One fixed contract the partner must answer in
   (`{ ok, reason }`), or a per-connector mapping (which field says confirmed,
   which carries the reason)?
3. **Whose words reach the visitor.** The partner's reason verbatim (capped and
   stripped, as SM1186 does), only when the partner marks it as for the visitor,
   or always a sentence the site's owner wrote per outcome?
4. **A form with a partner target and a local target.** Refuse that pairing
   when the connector is the system of record, or allow it with the local copy
   marked as a copy of a failed post?
5. **Sourced columns on every door.** Should an edit through the control API, MCP
   and `lazysite-data.pl` all be routed to the source, or should a sourced column
   be writable only through the manager, where the owner sees the partner's
   answer?
6. **After a write.** Re-read the one row from the source at once, or show the
   value the source returned in its answer until the next refresh?
7. **Retry.** Is a failed post ever retried by the engine, or is retrying always
   the visitor's choice? A retry needs an idempotency key the partner accepts.

# Related

[[SM1364]] (reading from a source; its "Writing back: none" is superseded by
this filing), [[SM842]] (one way to deliver, the connector handler), [[SM579]]
(connectors and their modes), [[SM790]] (the connector does not trust the
response).
