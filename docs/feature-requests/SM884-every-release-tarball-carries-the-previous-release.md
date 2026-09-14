---
id: SM884
title: "SM884: every release tarball carries the previous release inside it"
subtitle: "`git archive` includes download/, and download/ holds a full release. So 0.14.1's tarball is 24.5 MB of which about 18 MB is a copy of 0.14.0 - and the figure COMPOUNDS: 0.14.2 would carry 0.14.1's 27 MB set, 0.14.3 would carry that again. The fix is one export-ignore line, and it wants to land before the next cut rather than after it."
brand: plain
standard-margins: true
status: candidate
status-note: "FOUND 2026-09-14 while refreshing download/ for the 0.14.1 record: the new tarball was 24.5 MB against 0.14.0's 14.9 MB, a 64% jump in a PATCH release, which is not a plausible amount of engine to add in eight fixes. `tar tzvf` says why - lazysite-0.14.1/download/ holds lazysite-0.14.0.tar.gz (14.9 MB) plus the four 0.14.0 debs. LONGSTANDING, not new: 0.13.13, 0.13.16 and 0.14.0 each embed eight download/ entries too. It only became expensive at this cut because download/ previously held the small 0.12.1 set and now holds a full modern release. THE FIX: release.sh packages with `git archive`, which honours .gitattributes export-ignore, and .gitattributes currently declares none - so `download/ export-ignore` excludes it, with a test that the tarball contains no download/ entries. NOT DONE IN 0.14.1: found after the tag was cut, so the shipped tarball has the defect."
---

# The measurement

`download/lazysite-0.14.1.tar.gz` is **24,545,035 bytes**. Its largest members:

| bytes | path inside the tarball |
| --- | --- |
| 14,890,393 | `lazysite-0.14.1/download/lazysite-0.14.0.tar.gz` |
| 2,049,720 | `lazysite-0.14.1/download/lazysite-common_0.14.0-1_all.deb` |
| 828,429 | `lazysite-0.14.1/CHANGELOG.md` |
| 413,038 | `lazysite-0.14.1/lazysite-processor.pl` |
| 360,100 | `lazysite-0.14.1/download/lazysite-apache_0.14.0-1_all.deb` |
| 360,064 | `lazysite-0.14.1/download/lazysite-hestia_0.14.0-1_all.deb` |
| 359,260 | `lazysite-0.14.1/download/lazysite-nginx_0.14.0-1_all.deb` |

**Roughly 18 MB of a 24.5 MB release is the previous release.** The engine is
about 6 MB.

# It is not new, and that is the point

| release | tarball | `download/` entries inside |
| --- | --- | --- |
| 0.13.13 | 14.78 MB | 8 |
| 0.13.16 | 14.88 MB | 8 |
| 0.14.0 | 14.89 MB | 8 |
| 0.14.1 | **24.55 MB** | 8 |

Every one of them shipped `download/`. The reason nobody noticed is that until
this cycle `download/` held the **0.12.1** set, which was small - the README's
old "about 8 MB" line. Replacing it with a full 0.14.0 set during the 0.14.0
cycle is what turned a quiet inefficiency into ten megabytes.

# Why it needs fixing before the next cut rather than after

It compounds. `download/` holds one release, and the tarball embeds whatever is
in it:

- 0.14.1 ships 0.14.0's ~18 MB set → 24.5 MB
- 0.14.2 would ship 0.14.1's ~27 MB set → **~33 MB**
- 0.14.3 would ship that → **~40 MB**

Each figure is also permanent: `download/` exists because binaries in git are
permanent, and the tarballs land in `dist/` and on the download page. Left alone
this is not a stable overhead, it is a ratchet.

# The fix

`release.sh:768` packages with:

```
git -C "$STAGE" archive --format=tar.gz --prefix="lazysite-$VERSION/" ...
```

`git archive` honours `export-ignore` in `.gitattributes`, and the repository's
`.gitattributes` declares none. So:

```
download/ export-ignore
```

Plus a test asserting that a built tarball contains no `download/` member - the
kind of thing that is obvious once written and invisible for four releases
otherwise.

**Check the rest of the tree while there.** `download/` is the one that was
measured, but `dist/` and any other artefact directory deserve the same
question, and nobody has asked it.

# What is NOT wrong

`download/` itself is fine and staying. It is a deliberate trade, documented in
its own README, and `t/lint/113` keeps it pointing at the current stable. The
defect is that a *published artefact* is being copied into a *published
artefact*, not that the directory exists.

The 0.14.1 README now states the real figure and names this filing, so the
number nobody can explain does not sit there looking like engine growth.

# Related

[[SM113]] is the lint that keeps `download/` current. The filing that set
`download/` to a modern release is in the 0.14.0 CHANGELOG entry.
