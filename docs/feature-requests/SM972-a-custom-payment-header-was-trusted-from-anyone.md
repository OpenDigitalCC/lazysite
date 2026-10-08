---
id: SM972
title: "SM972: A custom payment header name was trusted from anyone"
subtitle: "With payment_header_verified set to a custom name and no auth_proxy_trusted, a visitor sending that header was served paid content."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-08
raised-by: the developer agent, found during SM944 S7 (moving the payment gate)
area: security
status-note: "SHIPPED (PENDING): apply_trust_gate strips custom payment_header_verified/_payer names, as SM960 did for auth_header_*, unless auth_proxy_trusted: true. t/integration/109: a visitor-sent custom header got the paid body before, 402 now."
---

# What was wrong

The paid-content gate (SM944 S7 moved it to `lazysite-processor/gates.pm`) reads
the header named by `payment_header_verified`, default `X-Payment-Verified`, and
serves the page when it is `1`. `apply_trust_gate` deletes untrusted identity and
payment headers - but for payment, only the fixed `X-Payment-*` names. SM960
extended it to custom `auth_header_*` names and not to the payment ones. With a
custom name configured (starter/docs/payment.md documents the key) and no
`auth_proxy_trusted`, a visitor sending `Payment-Ok: 1` got 200 and the paid
body; the default name was stripped and got 402. The built-in auth wrapper
strips only the fixed payment names, so it did not cover the custom ones either.

# The fix

`apply_trust_gate` adds `payment_header_verified` and `payment_header_payer` to
its list of configured custom names, stripped and logged unless
`auth_proxy_trusted: true`. The payment docs now show the flag and why.
**Behaviour change:** a site using custom payment header names without the flag
now gets 402 until it sets it.

# Evidence

t/integration/109: the control is 402; a visitor-sent custom header is 402 with
no body (both fail on the previous processor); from a trusted proxy the custom
header is honoured.

# Related

[[SM960]], [[SM944]].
