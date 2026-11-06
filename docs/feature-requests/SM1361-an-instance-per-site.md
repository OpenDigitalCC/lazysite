---
id: SM1361
title: "SM1361: an instance per site: shared engine and catalogue, create from a brief, move to a domain, paging"
subtitle: "Many small instances in one container, sharing one read-only engine and one layout catalogue, each created the same way from a brief and movable as one folder to its own domain or to Hestia."
brand: plain
standard-margins: true
status: candidate
raised: 2026-11-06
raised-by: "release manager (SM1350 discussion)"
area: platform
status-note: "Filed 2026-11-06 under SM1350. Needs a scale test on a scratch host, never the shared host."
---

# Proposed

- **Shared engine:** one engine release, read-only, serves every instance in the container. Each instance has only its own content and data folders.
  - Upgrading is one script, instance by instance, with each instance's upgrade steps logged.
  - A canary instance goes first.
- **Shared catalogue:** layouts and themes come from one read-only catalogue. An instance writes copies only where it changes one (a copy, as SM1354). Activation writes no per-instance mirror of an unchanged catalogue theme.
- **Front:**
  - a dedicated Caddy or nginx routes `<name>.<presales-domain>` to the instance, under one wildcard certificate;
  - no per-site virtual host;
  - the engine adds nothing to the web server's own configuration (standing rule).
- **Create from a brief:** `lazysite site-create` takes a name, layout, theme, owner account, the pages, and any wizard data to preload. It is idempotent and repeatable, and prints what it made.
- **Move to a domain:** export the instance, with its content history, accounts, data, form submissions and client room, then import it on Hestia or another host.
  - The old subdomain keeps a 301 to the new domain.
  - A dry run lists what will move.
- **Paging:** every list that grows (accounts, groups, submissions, room messages, rows, photo queue, history) pages in the manager and in the connector tools.
- **Scale test:** 2500 instances on a scratch host, measuring memory per idle instance, first-request time, upgrade time for all of them, and inode use.

# Questions for ruling

1. Container runtime: one container with many instances, or one container per instance?
2. Does an instance's notification email use one shared sending account, with Reply-To set per site, and a per-site rate limit?
