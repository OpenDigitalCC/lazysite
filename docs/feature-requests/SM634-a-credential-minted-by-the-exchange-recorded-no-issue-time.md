---
title: "SM634: the pairing-key exchange minted a credential and never recorded when, so Sessions & Keys said 'Issued: unknown' for the credentials an estate has most of"
subtitle: "Operator report, 2026-08-27: 'sessions and keys - issued is always unknown'"
brand: plain
standard-margins: true
status: shipped
status-note: "SHIPPED in 0.11.3 (2026-08-27). THE PAGE WAS RIGHT: nothing had recorded it. cmd_token sets cred_issued_at and cmd_connect_code sets it; cmd_token_exchange - the PAIRING-KEY path, which is how an AI partner normally obtains a credential from an agent brief - did not. So the estate had an issue time for exactly the credentials it has fewest of, and 'unknown' for the ordinary case. WHY IT MATTERS BEYOND THE COLUMN: 'when was this issued' is the question an operator asks when deciding whether a credential is stale, and the answer was missing on the ones most likely to be. It is also the immutable time an absolute session cap would measure from (SM614), so the gap sits under anything built on it later. cred_used_at is cleared at the same time and for the same reason cmd_token clears it: this is a NEW credential, and a first-use mark inherited from the previous one would say it had already been used - a record that is present and false, which is worse than one that is absent. NOT BACKFILLED, deliberately: a credential minted before this has no recorded issue time, and inventing one from a file mtime would be a guess presented as a record. Those keep saying unknown, which is true. The test reads the SUBS rather than asserting on one line, so a minting path added later without the record is caught by the same assertion instead of needing its own."
---

# Three ways to mint a credential, two of which recorded it

| Path | Recorded `cred_issued_at` |
|---|---|
| `cmd_token` - operator generates one | yes |
| `cmd_connect_code` - OAuth connect code | yes |
| **`cmd_token_exchange`** - agent redeems a pairing key | **no** |

The third is the one an AI partner uses.
