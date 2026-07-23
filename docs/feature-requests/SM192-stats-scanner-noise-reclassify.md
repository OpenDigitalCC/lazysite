---
title: "SM192 - Stats classifier: reclassify SPA/scanner probe noise (manifest + secret fishing)"
subtitle: "Build-manifest and secret-probe 404s inflate the human and AI counts; add them to the noise taxonomy, and drop referrer spam from the reports"
brand: plain
status: candidate
status-note: "IMPLEMENTED on claude/cluster-a-plus-sm192 (2026-07-23): classify() gains a status arg; SPA/build-manifest names -> noise when 404 (a genuine 200 manifest.json stays human), SECRET_RE -> noise UA-independently (path beats UA), and a built-in REF_SPAM_RE drops referrer-spam hosts (binance et al.) from the external-referrers report. Tests in 01-stats-classify.t. NOT done: an operator config key for referrer-spam (built-in list only, mirroring the design's 'optional'). Report accuracy only; no migration. Awaiting gate + vcs-review."
---

# SM192 - Stats classifier: reclassify SPA/scanner probe noise

## Why

The visitor-stats classifier (`plugins/stats.pl`) sorts each request into people /
AI assistants / bots / noise by path (`NOISE_RE`, `INFRA_RE`) and user-agent,
first match wins. Field analysis of a live site surfaced two mis-classifications
that inflate the headline counts:

1. **Human count inflated by SPA-tooling probes.** The top "human" 404s were
   `/config.json`, `/manifest.json`, `/asset-manifest.json`,
   `/_next/build-manifest.json`, `/.vite/manifest.json` - build-manifest probe
   sequences from SPA / framework scanners, not people. A lazysite site serves no
   SPA build, so a (404) request for a build manifest is a probe. True human
   traffic was perhaps 10-15% lower than reported (the trend and peaks stand
   regardless).
2. **AI count polluted by secret-fishing scanners.** `/secrets.json` (8 hits, all
   404) was classified AI because the client wore an assistant user-agent - either
   a scanner spoofing the UA, or an assistant prompted to fish. Path noise should
   win over UA here.

Separately: 404s were ~45% of all responses - almost entirely scanner noise (the
wp-admin cluster, already caught, plus this manifest/secret cluster, not) - and
referrer spam (e.g. `binance.com`, 15 referrals) shows up in the top-referrers
list.

## Design

All built-in, so every site benefits without per-site config (the existing
`noise_paths` config stays as the operator escape hatch):

1. **Build-manifest probes -> noise.** Add a pattern to `NOISE_RE` for the common
   SPA/build-manifest names (`asset-manifest.json`, `build-manifest.json`,
   `/_next/`, `/.vite/`, `/config.json`). Gate on a 404 where the classifier has
   the status: a manifest that actually 200s (a real PWA `/manifest.json`) is
   legitimate and must stay classified normally - only the 404 probe is noise.
   `classify()` already runs per log line, so thread the status in and apply
   "build-manifest name AND 404 -> noise".
2. **Secret-fishing probes -> noise (over UA).** Add `/secrets.json` and the
   obvious secret/credential probe names to `NOISE_RE`. Because path noise is
   checked before the user-agent classification, this reclassifies a UA-spoofing
   scanner as noise rather than AI. These are also a security signal - good
   candidates to feed the bad-URL blocker's scanner heuristics (SM128).
3. **Referrer-spam denylist for the reports.** Filter known referrer-spam hosts
   (e.g. `binance.com` and the usual list) out of the top-referrers report - a
   small built-in denylist, optionally with a config key mirroring `noise_paths`.

## Why it is cheap

The taxonomy already exists (`NOISE_RE` / `INFRA_RE` / `classify()`); these are
pattern additions plus threading the status into the manifest rule. No new store
and no migration - the reports simply get more accurate (the human and AI counts
drop toward the true figure; the trend is unchanged).

## Tests

- A 404 for `/asset-manifest.json` / `/_next/build-manifest.json` / `/secrets.json`
  classifies as noise, not human/AI; a 200 `/manifest.json` does not.
- A scanner wearing an assistant user-agent that hits `/secrets.json` is noise,
  not AI.
- The top-referrers report omits a denylisted spam host.

Related: `plugins/stats.pl` (`NOISE_RE`, `INFRA_RE`, `classify()`, the
`noise_paths` config), the bad-URL blocker (SM128 - a shared scanner signal), and
the security write-ups (secret-probe patterns).
