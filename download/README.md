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

    lazysite-0.14.4.tar.gz              the whole engine, for any host
    lazysite-0.14.4.tar.gz.sha256       its checksum
    lazysite-common_0.14.4-1_all.deb    the engine (required)
    lazysite-nginx_0.14.4-1_all.deb     nginx glue
    lazysite-apache_0.14.4-1_all.deb    Apache glue
    lazysite-hestia_0.14.4-1_all.deb    Hestia glue
    lazysite-skill-0.14.4.zip           the claude.ai skill (SM887) - carries lazysite-common

# Which one do I want

**On Debian or Ubuntu:** `lazysite-common` plus the one package for your web
server. The glue packages carry the vhost templates and nothing else, which is
why they are small and why installing two of them is not useful.

    sudo dpkg -i lazysite-common_0.14.4-1_all.deb lazysite-nginx_0.14.4-1_all.deb

**Anywhere else, or to install without root:** the tarball. Verify it first -
the checksum beside it is the one the release gate recorded:

    sha256sum -c lazysite-0.14.4.tar.gz.sha256

# Why the repository and not a release asset

Because somebody asked to download it and this is the shortest path from a
repository to a file. It is a deliberate trade: **binaries in git are permanent**
- nothing removes them - so this directory holds ONE release, replaced rather
than accumulated.

**The cost has grown sharply, and the figure here is measured rather than
estimated.** This directory used to say "about 8 MB" per release. The tarball
below is **34.2 MB**, and with the four packages this release adds roughly
**37 MB** to the history, permanently.

**Most of that is not the engine.** About 27.7 MB of the tarball - **81%** - is
a copy of the PREVIOUS release, because `git archive` includes this directory in
the release it builds, and that copy contains ITS predecessor in turn. The
engine itself is roughly 6.5 MB.

**This is the last release with that defect.** SM884 is fixed - one
`export-ignore` line, measured at 34,185,929 bytes before and 6,481,528 after -
and it lands in the next release. The fix was committed after this build had
already started, which is why the number here is still the large one.

That is not an argument against the trade; it is the trade at a price that was
wrong for a reason now understood and closed.

The durable record is the tag. Any release here can be rebuilt from its tag with
`tools/release.sh`, and the tags go back much further than this directory ever
will.

# Keeping it honest

`t/lint/113` asserts that what is here matches the newest **stable** row in
`docs/releases/GATE-LOG.md` - the release log, not the VERSION file, because
VERSION tracks the last release on ANY channel and would point at an edge cut.

That check exists because a download directory is exactly the kind of thing that
goes stale invisibly: nothing fails, nothing warns, and somebody downloads a
year-old build believing it is current. The lint fails the release instead - and
it did exactly that here, the moment this release was recorded as stable while
the directory still held its predecessor.

It also refuses any OTHER version number anywhere on this page, which is why the
paragraph above gives sizes and not the release they came from: an install line
carrying a stale version is copy-pasteable and wrong, and prose explaining a
stale version looks exactly like one to a reader skimming for a command.
