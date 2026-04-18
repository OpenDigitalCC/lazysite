---
title: Payment
subtitle: Gate content behind x402 payments with optional member bypass.
tags:
  - configuration
---

## Payment

Pages can require payment via the x402 HTTP payment protocol. The
processor returns `402 Payment Required` with payment terms. An
upstream proxy validates proof and sets `X-Payment-Verified`.
Members in specified groups bypass payment.

### Protecting a page

    ---
    title: Premium Article
    payment: required
    payment_amount: 0.01
    payment_currency: USD
    payment_network: base
    payment_address: 0x1234...
    ---

### Front matter keys

- `payment: required` - enables payment gate
- `payment_amount` - decimal amount (e.g. `0.01`)
- `payment_currency` - currency code (e.g. `USD`)
- `payment_network` - blockchain network (e.g. `base`)
- `payment_address` - recipient wallet address
- `payment_asset` - token contract address (defaults to USDC)
- `payment_description` - description shown to payer

### Member bypass

Add `auth_groups:` to let group members skip payment:

    ---
    payment: required
    payment_amount: 0.01
    payment_currency: USD
    payment_network: base
    payment_address: 0x1234...
    auth_groups:
      - members
    ---

### Custom 402 page

Create `402.md` with context variables:

- `[% payment_amount %]` - amount
- `[% payment_currency %]` - currency
- `[% payment_address %]` - wallet address
- `[% payment_description %]` - description

### TT variables on paid pages

- `[% payment_paid %]` - 1 if payment verified
- `[% payment_payer %]` - payer wallet address
- `[% payment_bypassed %]` - 1 if group bypass applied

### Notes

- Payment-gated pages are never cached
- Responses include `Cache-Control: no-store, private`
- Proof validation is delegated to an upstream proxy
- `lazysite-payment-demo.pl` provides demo mode for testing
- [Payment guide](/docs/payment) - full setup and configuration
