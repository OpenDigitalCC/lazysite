---
id: SM905
title: "SM905: an uploaded file reaches a person and never a service, and four small gaps are why"
subtitle: "The email handler carries uploads as base64 and the connector handler - whose whole purpose is to POST a submission to a URL the operator controls - does not, though the files are in scope where it runs. Add the capture attribute the grammar omits, the table column that would point at the images, and the action that would turn uploads on, and the photograph-to-OCR hand-off needs no new concepts at all."
brand: plain
standard-margins: true
status: partial
status-note: "U1 SHIPPED INERT IN 0.15.0 AND WORKS FROM THE NEXT RELEASE; U3 SHIPPED AND WORKS. The 0.15.0 claim for U1 was wrong in practice and the edge walk of TEST-PLAN-0150 found it (T7, 2026-09-28): the handler built `$payload{files}` as an array reference and `Connectors::call` refused any payload value that was a reference - 'a payload carries text values only, never a file or a structure' - so the photograph reached the connector layer and stopped. The two halves were each correct on their own terms and had never been run against each other on a host. Worse, THIS FILING'S OWN TEST PASSED THROUGHOUT, because it replaced `Connectors::call` with a stub that accepts anything: a mock more permissive than the thing it stands for tests the mock. The release manager ruled the exception on 2026-09-28 - `files` is the one key that may hold a structure, declared and capped, and every other reference is refused as before - and t/unit/forms/20 now hands the real `call` exactly what the handler built, proven by putting the old rule back and watching that subtest fail. U1 AND U3 ORIGINALLY: U4 and U5 remain and are named at the end of this note. U1 built on the filing's own recommendation for the two questions it left open: inline rather than by reference, because a signed URL needs the destination to reach back into this host and SM579's boundary is that there is no listener; and a configurable ceiling defaulting LOW - attach_max_kb at 1024, below a phone photograph, so raising it is a decision somebody makes. A request over the ceiling is REFUSED with the size, the ceiling and the setting, because a truncated payload leaves the destination unable to tell it was given part of a photograph. A malformed ceiling falls back to the default rather than to no limit, which a sabotage forced: the first version of the test asserted only that the refusal happened, and passed with the validation removed, because a non-numeric ceiling numifies to zero and refuses everything. U3 renders `capture`, bare or with `user` / `environment`; any other value is dropped rather than emitted as an attribute no browser honours. t/unit/forms/20 and 21 cover both, four sabotages between them. U2 was never work - it is the observation that the email handler was the template, and it was. U4 and U5 REMAIN: the table handler still stores no pointer to the uploaded files, and the three upload_* keys the form handler reads still have no action that writes them, which needs a control-API surface rather than a line."
raised: 2026-09-27
raised-by: site agent (proposal filed to the dev inbox, driven by the expo lead form)
area: forms, connectors
---

# Where this comes from

opendigital.cc ran a public lead form at an expo. Cards were typed in by hand or
pasted as text a phone had already read. The release manager's direction was
recorded with it: native device integrations matter from here, and the real-time
actions should hand a card off to be read the same way a recording will be handed
to a speech-to-text service.

The site agent filed three proposals. This filing is the part of them that is one
piece of work, **grouped by cause rather than by report**, as [[SM888]] was: a
file a visitor uploads can reach a person and cannot reach a service, and four
separate small omissions are why. The fourth proposal, making the
Permissions-Policy configurable, is [[SM710]] and its design note has been added
there rather than duplicated here.

**Nothing in this filing is a defect.** Every row is a capability the engine does
not have yet.

# Verified against the tree, not relayed

Each claim below was checked in the 0.15.0 tree before being written down, because
a filing that repeats a report without measuring it is a filing nobody can act on.

| Ref | The gap | Verified |
| --- | --- | --- |
| U1 | The **connector** handler sends visible text fields and nothing else | `Handlers.pm:1257` passes `{ _visible($fields) }` to `Connectors::call`. `$ctx` is in scope on the line above, used for origin, actor and trigger; `$ctx->{files}` is never read |
| U2 | The **email** handler already does it, so there is a working template a few lines away | `attach_files` is in its schema at `Handlers.pm:84`, read at 1214, and the payload gains a `files` array of filename, type, size and base64 data |
| U3 | The form grammar renders `accept`, `multiple` and `required` on a file input, but not `capture` | `lazysite-processor.pl:4510` builds the input from exactly those three |
| U4 | The **table** handler stores no pointer to the uploaded files | `_save_uploads` has one caller, `Handlers.pm:1111`, inside `_to_file`. With `keep_copy` the images land under the submissions tree and are named in the submissions record; the table row an operator works from has nothing |
| U5 | The three upload keys the form handler reads have no action that writes them | `plugins/form-handler.pl:297-299` reads `upload_max_kb`, `upload_max_files` and `upload_accept` from the form's conf; the only writer is `form-targets-save`, which writes `targets:` |

# Why U1 is the one that matters

The other four are conveniences. U1 is the difference between a photograph
being **stored** and being **processed**, and it is the whole of the direction the
release manager described.

A connector is already the governed way out: an operator-vetted destination, a
credential in the reserved tree, declared modes, a rate cap, and one audit record
per call. Every control that ought to apply to sending a customer's photograph to
a third party is already built and already applies. What is missing is that the
payload cannot contain the photograph.

So the change is additive and small: `attach_files` on the connector handler,
with the same name, the same shape and the same default of false as the email
handler's. The answer comes back on the connector's existing JSON contract, which
is how the read text returns to the site.

# What needs deciding before U1 is built

Two questions, and they are the release manager's rather than mine.

1. **A size ceiling for an attached payload.** A phone photograph is 3 to 8 MB
   and a recording is larger. The connector's answer cap is 64 KB today, which is
   about what comes back rather than what goes out, so this is a new number.
2. **Inline or by reference.** Base64 inline is simple and is what the email
   handler does. A signed URL to the stored copy keeps the request small and
   makes the destination fetch it, which is a different trust shape: the service
   would need to reach this host, and the connector's whole design is that
   traffic goes outward only.

My recommendation is inline with a configurable ceiling, defaulting low, and to
leave by-reference until something actually needs it. Inline reuses a proven
path; by-reference introduces an inbound leg, and [[SM579]]'s boundary is that
there is no listener.

# Sequencing

U1 first, and on its own: it carries a compatibility surface (a new field in a
payload a site's own endpoint parses) and the two decisions above. U3 and U5 are
an afternoon each and can ride any release. U4 wants a declared column name, so
it is a small design question about descriptors rather than a small change.

U2 is not work. It is the template U1 copies.

# Related

[[SM710]] (the Permissions-Policy half of the same proposal, where a capture
widget is actually blocked today), [[SM579]] (the connector, its modes, caps and
audit record), [[SM888]] (grouped by cause, not by report),
[[feedback_peer_claims_need_evidence]] (why every row above carries a line
number).
