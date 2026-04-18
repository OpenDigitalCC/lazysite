---
title: Payment
subtitle: Gate content behind x402 payments with member bypass.
register:
  - sitemap.xml
  - llms.txt
---

## Overview

lazysite supports the x402 HTTP payment protocol. Pages can require
payment before being served. When an unpaid request arrives, the
processor returns `402 Payment Required` with an `X-Payment-Response`
header describing payment terms. An x402-compatible wallet or browser
extension reads this header, makes the on-chain payment, and retries
the request with proof.

Payment proof validation is delegated to an upstream proxy. The
processor trusts an `X-Payment-Verified` header, the same pattern
as `X-Remote-User` for authentication.

## Protecting a page

```yaml
---
title: Premium Article
payment: required
payment_amount: 0.01
payment_currency: USD
payment_network: base
payment_address: 0x1234...your-wallet-address
payment_description: Access to premium article
---
```

### Front matter keys

`payment: required`
: Enables the payment gate. Only value is `required`.

`payment_amount`
: Amount in human-readable decimal (e.g. `0.01` for one cent USD).

`payment_currency`
: Currency code for display. Example: `USD`.

`payment_network`
: Blockchain network. Example: `base`, `ethereum`, `polygon`.

`payment_address`
: Recipient wallet address.

`payment_asset`
: Token contract address. Defaults to USDC on the specified network
  if not set.

`payment_description`
: Optional description shown to the payer.

## Member bypass

Members in specified groups skip payment entirely. Add `auth_groups:`
to the payment-gated page:

```yaml
---
title: Members Content
payment: required
payment_amount: 0.01
payment_currency: USD
payment_network: base
payment_address: 0x1234...
auth_groups:
  - members
  - sponsors
---
```

Authenticated users in `members` or `sponsors` see the content
without paying. All other users (including unauthenticated) see the
402 payment page.

## Custom 402 page

Create `402.md` in the docroot. These TT variables are available:

- `[% payment_amount %]` - amount from front matter
- `[% payment_currency %]` - currency from front matter
- `[% payment_network %]` - network from front matter
- `[% payment_address %]` - wallet address
- `[% payment_description %]` - description text

If `402.md` does not exist, a minimal built-in page is shown.

## TT variables on paid pages

After payment is verified:

- `[% payment_paid %]` - 1 if payment proof verified
- `[% payment_payer %]` - payer wallet address if available
- `[% payment_bypassed %]` - 1 if access granted via group membership
- `[% payment_amount %]` - amount from front matter
- `[% payment_currency %]` - currency from front matter
- `[% payment_address %]` - wallet address

## x402 response header

The `X-Payment-Response` header returned with 402 responses contains
JSON:

```json
{
  "version": "1.0",
  "accepts": [{
    "scheme": "exact",
    "network": "base",
    "maxAmountRequired": "10000",
    "to": "0x1234...",
    "asset": "0x...",
    "extra": {
      "name": "USDC",
      "version": "1"
    }
  }]
}
```

`maxAmountRequired` is in the asset's smallest unit (USDC has 6
decimals, so `0.01` USD = `10000`).

## Upstream payment proxy

In production, configure a payment proxy to:

1. Intercept requests with `X-Payment-Proof` header
2. Validate the on-chain payment
3. Set `X-Payment-Verified: 1` and optionally `X-Payment-Payer`
4. Forward to the processor

Configure header names in `lazysite/lazysite.conf`:

```yaml
payment_header_verified: X-Payment-Verified
payment_header_payer: X-Payment-Payer
```

## Demo mode

`lazysite-payment-demo.pl` simulates payment via signed cookies for
testing. **Not for production use.**

Simulate payment:

    /cgi-bin/lazysite-payment-demo.pl?action=pay&page=/premium&amount=0.01

Clear payment:

    /cgi-bin/lazysite-payment-demo.pl?action=unpay&page=/premium

Demo payments expire after 1 hour.

The dev server auto-detects the demo script and routes requests
through it when present.

## Cache behaviour

Payment-gated pages are never cached to disk and always include
`Cache-Control: no-store, private`. This prevents paid content from
being served without payment verification.

## Further reading

- [Authentication](/docs/auth) - auth groups used for member bypass
- [Payment feature reference](/docs/features/configuration/payment)
