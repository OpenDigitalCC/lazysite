---
title: "lazysite - download"
subtitle: "The current STABLE release, tracked in the repository so it can be downloaded without a build"
brand: plain
standard-margins: true
---

# What is here

**The current stable release, and only that.** Not the newest cut - the newest
**stable** one. Edge and beta builds are deliberately absent: they exist to be
tested by people who know they are testing, and a download link is not that.

    lazysite-0.12.1.tar.gz              the whole engine, for any host
    lazysite-0.12.1.tar.gz.sha256       its checksum
    lazysite-common_0.12.1-1_all.deb    the engine (required)
    lazysite-nginx_0.12.1-1_all.deb     nginx glue
    lazysite-apache_0.12.1-1_all.deb    Apache glue
    lazysite-hestia_0.12.1-1_all.deb    Hestia glue

# Which one do I want

**On Debian or Ubuntu:** `lazysite-common` plus the one package for your web
server. The glue packages carry the vhost templates and nothing else, which is
why they are small and why installing two of them is not useful.

    sudo dpkg -i lazysite-common_0.12.1-1_all.deb lazysite-nginx_0.12.1-1_all.deb

**Anywhere else, or to install without root:** the tarball. Verify it first -
the checksum beside it is the one the release gate recorded:

    sha256sum -c lazysite-0.12.1.tar.gz.sha256

# Why the repository and not a release asset

Because somebody asked to download it and this is the shortest path from a
repository to a file. It is a deliberate trade: **binaries in git are permanent**
- every stable release adds about 8 MB to the history and nothing removes it -
so this directory holds ONE release, replaced rather than accumulated.

The durable record is the tag. Any release here can be rebuilt from `v0.12.1`
with `tools/release.sh`, and the tags go back much further than this directory
ever will.

# Keeping it honest

`t/lint/113` asserts that what is here matches the newest **stable** row in
`docs/releases/GATE-LOG.md` - the release log, not the VERSION file, because
VERSION tracks the last release on ANY channel and would point at an edge cut.

That check exists because a download directory is exactly the kind of thing that
goes stale invisibly: nothing fails, nothing warns, and somebody downloads a
year-old build believing it is current. The lint fails the release instead.
