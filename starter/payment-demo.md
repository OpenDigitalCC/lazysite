---
title: Premium Content
subtitle: This page requires payment to access.
payment: required
payment_amount: 0.01
payment_currency: USD
payment_network: base
payment_address: 0x0000000000000000000000000000000000000000
payment_description: Access to premium content demo
search: false
---

## Premium content

You have paid for access to this page.

[% IF payment_bypassed %]
(Access granted via group membership - no payment required.)
[% END %]

[% IF payment_paid %]
Payment received from [% payment_payer || 'wallet' %].
[% END %]

This is the protected content that only paying visitors can see.

[Simulate unpayment](/cgi-bin/payment-demo.pl?action=unpay&page=/payment-demo)
