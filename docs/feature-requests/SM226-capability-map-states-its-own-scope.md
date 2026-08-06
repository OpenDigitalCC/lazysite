---
title: "SM226 - A capability map should say what question it answers"
subtitle: "describe_capabilities returns both what the platform can do and what this account holds. Readers flatten the two and conclude a capability they were not granted is a capability that does not exist."
brand: plain
status: candidate
status-note: "Raised 2026-08-06 from the Golden Link partner review, where a tabulated 'no' in the holds block was read as a platform limitation and designed around. Small change, high leverage. Implementation targeted for the next release."
---

# SM226 - the capability map should state its own scope

## Why

`describe_capabilities` returns two different kinds of fact in one response:

- `capabilities` - every capability the platform defines, with a title and what
  it unlocks. This describes **the platform**.
- `holds.capabilities` - a flat map of capability name to true or false. This
  describes **this account**.

The distinction is obvious from the structure once you know it is there. In
practice readers flatten it. A partner reviewing two connections in August 2026
produced this table and reasoned from it:

| Capability | Test Sites | Lazysite.agency |
|---|---|---|
| read_submissions | yes | **no** |
| manage_domains | yes | **no** |
| audit | **no** | **no** |

They then wrote *"the agency account cannot register a domain or apply a site
package, which is precisely what the Studio app has to do"* - correct - and
separately concluded that reading form submissions was not something the
platform offered, and designed a replacement store. `read_submissions` is a
deliberate least-privilege read capability that does exactly what they needed.

The reading is understandable. A boolean false against a capability name, in a
response headed "capabilities", reads as absence. Nothing in the response says
"this is a grant, not an inventory".

## What is true today

`Lazysite::Capabilities::describe` builds:

```perl
my %map = (
    channels     => \%channels,
    capabilities => \%capabilities,
    tasks        => \@TASKS,
    engine_owned => \@ENGINE_OWNED,
);
if ( $opt{caps} ) {
    $map{holds} = {
        account      => ...,
        capabilities => { map { $_ => ( $caps->{$_} ? $T : $F ) } @CAP_KEYS },
    };
}
```

The `holds` key is well named. It is also the only signal, it is a sibling of
`capabilities` rather than visibly subordinate to it, and the tool description
mentions it only in a trailing clause: *"and - under 'holds' - what THIS account
currently has."*

## What to build

### 1. A scope statement in the response

Add an explicit field to `holds` saying what it means and what it does not:

```
holds => {
    account => '...',
    scope   => 'What THIS account has been granted. A false value means "not
                granted to this account", never "not available in lazysite" -
                see capabilities for what the platform offers, and ask the
                operator for a grant.',
    capabilities => { ... },
}
```

Prose in the payload is unusual and is the right tool here: the consumer is a
language model, and the misreading is a language misreading.

### 2. Make the false values self-describing

Rather than a bare boolean, give each entry the reason it is false where one is
known - not granted, or gated by a channel that is off, or gated by a service
killswitch. `channel_service()` already maps channels to killswitches and
`action_channel_services()` already consumes it, so the killswitch case is
available without new machinery.

This also helps the operator case: "you hold `mcp` but the mcp service is off"
is a materially different answer from "you were not granted `mcp`", and today
both render as false.

### 3. Amend the tool description

State the distinction in the first sentence rather than the last clause.

## Verification

- A capability the account lacks reports a reason, and the reason distinguishes
  ungranted from service-disabled.
- The scope statement is present whenever `holds` is present.
- `t/unit/lib/05-capabilities.t` covers the new fields; the existing curation
  test for `unlocks` is unaffected.

## Not in scope

- Changing what any account holds.
- Exposing capabilities the account cannot see for reasons of confinement. This
  request adds explanation to what is already returned, and returns nothing new
  about other accounts.
