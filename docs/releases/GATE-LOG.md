---
title: "lazysite - release gate record"
subtitle: "Which commit each release was validated at, newest last. Appended by tools/release.sh."
brand: plain
standard-margins: true
---

# Why this file exists

A promotion review could establish which VERSION was being proposed and not
which COMMIT had been validated: the gate summary went to a terminal and to
`tmp/gate-result.txt`, which is gitignored. "The build that would go to beta is
not the build that was validated" was a reasonable conclusion and nothing cheap
could disprove it.

Every row is written by `tools/release.sh` after its gate passed and before it
tagged, so a row exists only for a build that was actually gated. The same facts
travel inside the artefact, in `release-manifest.json` under `validated`.

| Version | Channel | Commit | Files | Tests | Gated (UTC) |
|---|---|---|---|---|---|
| 0.10.16 | edge | `06566c426ac35c0a33b863bff10e034cd20f3fe1` | 462 | 8415 | 2026-08-19 16:52 |
| 0.10.17 | edge | `b03bece36db64d125a8b16243ade8190db0aa2e8` | 467 | 8470 | 2026-08-19 20:37 |
| 0.10.18 | edge | `5eb5409644cef3205f2fdc7c34dbed1cf876be1f` | 475 | 8565 | 2026-08-20 09:50 |
| 0.10.19 | beta | `158625c276d356175b661e263130948c1fc76d7d` | 477 | 8583 | 2026-08-20 12:12 |
| 0.10.20 | edge | `1139750893ee565881dcf6c4cb55ec3726ae5018` | 482 | 8642 | 2026-08-21 07:20 |
| 0.10.21 | beta | `f9404d97fd56b926eeea75f4be87557183d70510` | 491 | 8708 | 2026-08-21 10:00 |
| 0.10.22 | beta | `411349fcd782a381c48a07c851f3059fa44aeb1d` | 504 | 8807 | 2026-08-21 15:24 |
| 0.10.23 | edge | `41f82426d8c2a224c95947954c331aa9aa587ff7` | 520 | 8987 | 2026-08-21 21:58 |
| 0.10.24 | edge | `80b87cc06ce40edbd161932a807a47245f0f2151` | 521 | 8999 | 2026-08-22 00:18 |
| 0.10.25 | edge | `e1c82bfb8f0e72614943a31864288e094c33bd9b` | 521 | 9010 | 2026-08-22 09:50 |
| 0.10.26 | edge | `e80b12a57c26afecf82618dd4c458353ba9ff0fb` | 542 | 9193 | 2026-08-23 07:18 |
| 0.10.27 | edge | `e9016340ed4e7fbe2e57e6ae1b022bb16e12e7bd` | 554 | 9333 | 2026-08-23 13:34 |
| 0.10.28 | edge | `9af902f2540ca526e57c0f006bf0c16d26c9b630` | 563 | 9397 | 2026-08-23 22:05 |
| 0.10.29 | edge | `8b3feb747ce5abdc646c13d3ca09a44d9fae9749` | 574 | 9507 | 2026-08-24 12:06 |
| 0.10.30 | edge | `d5b03ad0ca46ddf536479e1014ede6f477e60e8b` | 580 | 9576 | 2026-08-24 19:03 |
