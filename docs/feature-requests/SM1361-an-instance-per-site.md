---
id: SM1361
title: "SM1361: an instance per site: shared engine and catalogue, create from a brief, move to a domain, paging"
subtitle: "Many small instances in one container, sharing one read-only engine and one layout catalogue, each created the same way from a brief and movable as one folder to its own domain or to Hestia."
brand: plain
standard-margins: true
status: partial
raised: 2026-11-06
raised-by: "release manager (SM1350 discussion)"
area: platform
status-note: "PARTIAL: the shared engine and the many-site container built on n788 for 0.16.9 (rulings 201, 205, 208, 210). Create from a brief, move to a domain, paging and the scale test remain."
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
   Ruled (205, 208): one container serves many site volumes.
2. Does an instance's notification email use one shared sending account, with Reply-To set per site, and a per-site rate limit?

# Built for 0.16.9 (n788)

The ruling
: Ruling 201 amends 200: Hestia sites keep their own engine, and the shared read-only
  engine is for volume-hosted sites in a container. Ruling 205 answers the design's
  questions, 208 settles the container's shape, and 210 decides that every site runs as
  www-data, with site-local extensions refused.

The shared engine
: The image carries the engine and its extensions, read-only, and marks itself with
  `SHARED-ENGINE` at the engine root. `install.pl --engine shared` (the marker's default)
  lays a site with no engine copy. On that engine only the image's own extensions run.

The container
: Ruling 208 shapes it:
  - the sites are folders in one volume, listed in `sites.conf`;
  - each site has its own pool (worker cap) and its own runtime;
  - nginx in front serves plain HTTP behind the operator's TLS;
  - `lazysite-sites` adds and removes a site without a restart.
: Each start brings each site to the image, and an image older than a site's state
  refuses that site, printing the restore command. A failed or damaged site answers 503
  and is named, and the container is unhealthy only when nginx or its supervisor is down.
  A one-site canary is a second container.
: A site whose end user takes it over moves to a dedicated service: Hestia, or a
  container of its own.

Tests
: `t/tools/391`, `t/tools/393`, `t/tools/210`, `t/unit/extensions/130`, `t/lint/392`. The
  real container walk is a by-hand step (ruling 204).

Not built yet
: Create from a brief, move to a domain, paging, and the 2500-instance scale test.
