---
title: Member Access Demo
subtitle: Members get free access. Others pay.
payment: required
payment_amount: 0.05
payment_currency: USD
payment_network: base
payment_address: 0x0000000000000000000000000000000000000000
auth_groups:
  - members
search: false
---

## Members get free access

If you are in the `members` group, you see this without paying.
Everyone else is shown the payment page.

[% IF payment_bypassed %]
Access granted via group membership.
[% ELSE %]
Access granted via payment.
[% END %]
