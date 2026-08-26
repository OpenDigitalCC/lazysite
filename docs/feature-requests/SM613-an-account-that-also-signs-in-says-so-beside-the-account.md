---
title: "SM613: the fact was on the page, in the column that made it read as a footnote about a button"
subtitle: "The operator, signed into the manager, read their own row in Active keys saying \"Key for: webdav\" and asked whether their manager session was governed by it"
brand: plain
standard-margins: true
status: shipped
status-note: "SHIPPED in 0.11.0 (stable, 2026-08-26), commit 137d74d1. FILED RETROSPECTIVELY 2026-08-26 during the 0.11.0 filing sweep, which found this ref stamped into the changelog with no filing behind it - the sweep's own gap, recorded rather than quietly closed. THE ANSWER IS NO: the key is a machine credential replayed over HTTP Basic, the manager is a cookie session, and revoking the key would not end that session. THE PAGE ALREADY KNEW - the row carried `interactive` and rendered it in the far-right action column, in place of the Revoke button. That is the right place for the REVOCATION consequence and the wrong place for the fact. In the action column it reads as a footnote about a control; the operator's question was about the ACCOUNT. The tag now sits beside the account name with the explanation on hover. `Key for` still lists only the channels the KEY opens, and the manager is not among them - saying it was would be false in the direction that matters, because it would imply revoking the key ends the session. THE GENERAL SHAPE, which is why this is worth a filing at all: a surface can hold the right datum in the wrong column and be indistinguishable, to a reader, from one that does not hold it. Three of 0.11.0's twelve entries are this shape, all three found by the operator reading a page and asking what it meant, none reachable by a gate."
---

# The question

> "Key for reports just webdav for my user, although I am using manager UI.
> Is the manager UI session managed also by this?"

# The answer, and where it already was

| | |
|---|---|
| Key | machine credential, HTTP Basic, replayed per request |
| Manager session | cookie, independent lifetime |
| Revoking the key | does **not** end the session |

The `interactive` flag was rendered where the Revoke button would be - correct
for what revocation does, and invisible as an answer to what the account is.
