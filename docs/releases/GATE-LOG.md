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
| 0.10.31 | edge | `509f4e026cc5f4725c3532ff4a1f40af783207a1` | 581 | 9604 | 2026-08-24 21:02 |
| 0.10.32 | edge | `f57b6cd2833eb2612f8568a091b0c0bbbe2333e8` | 614 | 10300 | 2026-08-25 12:01 |
| 0.10.33 | edge | `79f1cbd494db0c1ba6c8c2369122dafcdbbd4351` | 639 | 10661 | 2026-08-25 19:51 |
| 0.10.34 | beta | `22cb1ffe8bddd7a1fa98c16eccb1e094657823dd` | 639 | 10676 | 2026-08-25 23:18 |
| 0.11.0 | stable | `b1fc6998dfb03764327b852f8ae1b756fb4266d1` | 642 | 10782 | 2026-08-26 11:29 |
| 0.11.1 | stable | `93c47464311c802877ca01fecc7ca767c8729063` | 643 | 10816 | 2026-08-26 16:05 |
| 0.11.2 | edge | `955e1e73dddffa27da41235b10ba21bdfff3b966` | 656 | 11058 | 2026-08-26 20:44 |
| 0.11.3 | edge | `0d492fc9dfb9a5e97079486a08913389417436cb` | 682 | 11619 | 2026-08-27 21:39 |
| 0.11.4 | edge | `d732dc7c0317bc89950a7b27685af32a91efc38c` | 691 | 11729 | 2026-08-28 16:55 |
| 0.11.5 | edge | `6c39ba7914d6aa43d19ffc2f8b21bacffd8b9f4e` | 701 | 11813 | 2026-08-28 22:42 |
| 0.11.6 | beta | `62b354b5c69a54b3847905e522fd4a26c3f705ec` | 707 | 11899 | 2026-08-29 11:07 |
| 0.11.7 | stable | `4cb42b505ddcdae5cc35cdcb69a644ca77178dad` | 714 | 11926 | 2026-08-29 19:20 |
| 0.11.8 | edge | `5d1e7b7ca0c7e1572a1d561621429b083ea665f9` | 720 | 11973 | 2026-08-30 16:44 |
| 0.11.9 | edge | `cf64489bc8f4bd277bf30e382e432eaac0999ef0` | 736 | 12110 | 2026-08-31 20:35 |
| 0.11.10 | beta | `d62f9824ae407bd78e3ce0ef002864f93a5a7cac` | 738 | 12153 | 2026-09-01 13:42 |
| 0.11.11 | beta | `bfee09cfcf170474145b2a0aec0ebee9866556a5` | 745 | 12276 | 2026-09-02 11:40 |
| 0.11.12 | beta | `4ceb95218de8ee9da71cf8727d061c5816cf3d2e` | 747 | 12294 | 2026-09-02 15:49 |
| 0.12.0 | stable | `b6b284746ee48c661c3ec614583787635bcc65fb` | 749 | 12334 | 2026-09-02 19:38 |
| 0.12.1 | stable | `e707caabe22ed9ca124f0284841cd300be0ffcde` | 750 | 12350 | 2026-09-03 09:52 |
