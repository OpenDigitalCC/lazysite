---
id: SM1366
title: "SM1366: an Odoo call's audit row names the signed-in account"
subtitle: "The audit log records a signed-in visitor's Odoo call as session:<hash>. An operator reading the log cannot tell who made the call without matching hashes by hand. A call made under a signed-in account should name that account, and keep the session hash beside it."
brand: plain
standard-margins: true
status: candidate
raised: 2026-11-06
raised-by: "release manager, from an operator reading the audit log"
area: odoo
status-note: "Filed 2026-11-06. Not scheduled; proposed for 0.16.6."
---

# What happens

An Odoo call made by a signed-in visitor appears in the audit log as:

    session:84a4be1d0c9f40bd  authenticated  odoo-call  payslip-list -> lab.payslip.list  127.0.0.1  answered

- **Where:** `lib/Lazysite/Odoo.pm` `_with_visitor` sets the record's `actor` to `Lazysite::Odoo::Session::session_label( $c{odoo_session} )`, a 16-hex hash of the Odoo session id. The sign-in, two-factor and refresh paths (`record_call( ..., actor => session_label(...) )`) do the same.
- **Why the hash:** the session id is a credential, so a record names it by hash and never by value (design B). That stays right.
- **What is lost:** the account. Other log lines for the same request already name it. The processor's ACL line writes `user=odoo:<login>` for the same visitor. So the audit row is the one record that cannot say who acted.

# Proposed

- **Signed-in calls:** where the request carries a signed-in lazysite identity, the row's `actor` is that identity, written as everywhere else (e.g. `odoo:<login>`, or a local account name). The session hash moves to its own field, `session`, so a run of calls in one session can still be grouped.
- **Unknown identity:** where no identity is known (no identity cookie yet, or one that has ended and has not been refreshed), the actor stays the session hash, as today.
- **Failed sign-ins keep `login_label`:** a refused sign-in is a typed login, not an account, so the hash stays (no change).
- **The Audit page and `odoo-calls`:** show the account, with the session hash available on the row.
- **Tests:** a signed-in call records the account plus the session hash; a call with no identity records only the hash; a refused sign-in records no login in clear. Each fails with its change reverted.

# Not changed

- The session id is never written.
- The visitor id (`visitor`) for anonymous calls is unchanged.
