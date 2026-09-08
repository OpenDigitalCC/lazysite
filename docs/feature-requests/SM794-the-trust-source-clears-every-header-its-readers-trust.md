---
id: SM794
title: "SM794: the trust source clears every header its readers trust"
subtitle: "Security review, 0.13.8, VERIFIED AND REPRODUCED: lazysite-auth.pl sets LAZYSITE_AUTH_TRUSTED=1 but regenerates only two of the six trusted headers, and the C-1 gate then returns early and keeps the other four exactly as the client sent them. An ordinary logged-in visitor adds X-Payment-Verified: 1 and is served payment-gated content. A correctly-shipped edge closes it; the in-app gate that exists to backstop the edge does not."
brand: plain
standard-margins: true
status: shipped
status-note: "BUILT 2026-09-08 on claude/secrev-wild-request-path. lazysite-auth.pl now DELETES the four trusted headers it does not produce before it execs, so the boundary is produce-or-clear rather than produce-two-and-hope. t/lint/38 widened to the payment headers and given the new question - does the trust source clear or produce every trusted field its readers consume - which is the check whose absence let this stand."
---

# The finding, and what was verified here

Every claim was checked against the source before it was accepted, and the
mechanism was reproduced independently:

- `lazysite-auth.pl`'s success block sets `HTTP_X_REMOTE_USER`,
  `HTTP_X_REMOTE_GROUPS` and `LAZYSITE_AUTH_TRUSTED=1` (`:903`, `:911`, `:912`)
  and **never mentions** `HTTP_X_REMOTE_NAME`, `HTTP_X_REMOTE_EMAIL`,
  `HTTP_X_PAYMENT_VERIFIED` or `HTTP_X_PAYMENT_PAYER`.
- `apply_trust_gate` (`processor:2012-2017`) returns as soon as the sentinel is
  set, so its `delete` list never runs for an authenticated request.
- The payment gate reads `$ENV{HTTP_X_PAYMENT_VERIFIED}` (`:1431`) and the
  payer (`:1440`) and serves the gated content.

Reproduced in `tmp/trust-gate-repro.pl`. Anonymous and direct: all six
stripped. With a valid cookie: `USER` and `GROUPS` correctly overridden from
the cookie and the groups file, and

    HTTP_X_PAYMENT_VERIFIED=1  HTTP_X_PAYMENT_PAYER=0xATTACKER
    HTTP_X_REMOTE_NAME=Spoofed Name  HTTP_X_REMOTE_EMAIL=spoof@evil.test

still standing, as trusted values.

**The identity half is sound and that is worth stating**, because it is what
makes this a narrow finding rather than a broad one: user and group spoofing on
an authenticated request is fully defeated, groups are re-resolved fresh from
the groups file rather than taken from the cookie, and the sentinel is not
client-forgeable.

# Why the backstop missed it

`t/lint/38-trust-headers-gated-in-app.t` enforces "reads implies gates", and its
trigger is `HTTP_X_REMOTE_(?:USER|GROUPS|NAME|EMAIL)` - **the payment headers
are outside its alphabet entirely** - while `lazysite-auth.pl` is exempt as the
trust source. So nothing asked the one question that matters at a trust
boundary: does the source clear or produce *every* field its readers trust?

# What was built

**Produce or clear.** The success block now deletes the four headers it does
not produce, before it execs. The boundary is complete rather than partial.

**Clear rather than produce, for name and email, deliberately.** auth.pl could
resolve them from the account record, but the processor already does: when no
header carries a name it falls back to `_display_name_for` on the account
(`:2562-2565`). Producing the header in auth.pl would be a second answer to the
same question and a settings read on every request - the read whose cost
`read_settings`' own comment tracks through the `verify_token_ms` drift. So the
one producer stays where it is, and the header stops carrying a forgery.

The consequence is worth stating plainly: **`auth_name` on a cookie session now
comes from the account record instead of from the header**, which is the fix
rather than a side effect - "the header still wins where one is present" was
written for an upstream proxy that knows who the visitor is, and on a cookie
session there is no such upstream. `auth_email` is empty on that path unless a
proxy supplies it; it was previously only ever the client's own value.

**The lint learned the question.** t/lint/38 now covers `HTTP_X_PAYMENT_*` and
asks whether the trust source clears or produces each trusted field.

# Not done, and left for the release manager

The review's two related items are recorded rather than built:

- **`auth_proxy_trusted: true` has no hop check.** With the flag on, the gate
  returns early for every request and authz is read from the header with no
  cross-check, so a raw client naming a manager group is sufficient. That is
  the flag's designed meaning, and an `auth_proxy_trusted_from` CIDR allowlist
  checked against `REMOTE_ADDR` is a change to the flag's contract.
- **The security document contradicts itself** on whether the edge strip is
  required (`security.md:101-104` "defence in depth" versus `:707-709` "a hard
  requirement"). For user and groups the first is true; for the other four the
  second is. With this fix the first becomes true for all six, and the
  paragraphs should be reconciled saying so.

# Provenance

`inbox/2026-09-08-payment-and-trusted-header-gate-gap.md`, from the wild-facing
request-path review. Accepted after independent verification and reproduction.
