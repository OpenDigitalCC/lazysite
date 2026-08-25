---
title: "SM526: one answer to is-this-address-public"
subtitle: "Two address classifiers in Domains disagree, so a domain check can be told a mapped loopback or CGNAT address is this server."
brand: plain
standard-margins: true
status: shipped
status-note: "SHIPPED 0.10.32 (EDGE): _is_public_ip deleted; instance_public_ips filters its canonical_ip, resolved-domain and SERVER_ADDR candidates through _ip_is_public, the SSRF guard, so the module holds one classifier. Proving test t/unit/manager/99-one-answer-to-is-this-address-public.t drives the eight disagreeing inputs through instance_public_ips and pins that the second sub is gone. FOUND 2026-08-25 by the themes structural review, PROVEN by probe tmp/tl-probe-ip-twins.pl; class: correctness; recommended timing: 0.10.33. PLANNED under SM516 for 0.10.33 unless the operator pulls it forward. Manager/Domains.pm carries two answers to is-this-address-public: _ip_is_public, the SSRF guard at 1019-1042, and _is_public_ip, the self-address filter at 1140-1156. They disagree on 8 of 15 inputs - 100.64.0.1, 224.0.0.1, 240.0.0.1, 999.1.1.1, ::, fe90::1 and the IPv4-mapped ::ffff:127.0.0.1 and ::ffff:10.0.0.1 are all public to the second - so instance_public_ips can hand a mapped loopback or a CGNAT address to domain_check as this server, and the points-to-this-server check passes against it. Fix: delete _is_public_ip and call _ip_is_public."
---

# The finding

`Domains::_ip_is_public` (the SSRF guard, `Manager/Domains.pm 1019-1042`)
and `_is_public_ip` (the self-address filter, `Manager/Domains.pm
1140-1156`) disagree on 8 of 15 inputs: 100.64.0.1 (CGNAT),
224.0.0.1, 240.0.0.1, 999.1.1.1, `::`, `fe90::1`, and the IPv4-mapped
`::ffff:127.0.0.1` / `::ffff:10.0.0.1` are all "public" to the second. So
`instance_public_ips` can hand a mapped loopback or a CGNAT address to
`domain_check` as "this server", and the "points to this server" check
passes against it.

# Why it matters

Correctness: `domain_check` exists to tell an operator whether their
DNS points at this instance. When the list of "this server" addresses
includes loopback and CGNAT space, the check can say yes to a domain that
reaches nothing.

# The proving test

NEW `t/unit/manager/99-one-answer-to-is-this-address-public.t`:
`is(Lazysite::Manager::Domains::_is_public_ip('::ffff:127.0.0.1'), 0)`.

# Fix shape

Delete `_is_public_ip` and call `_ip_is_public` from the self-address
filter, so the module holds one classifier.
