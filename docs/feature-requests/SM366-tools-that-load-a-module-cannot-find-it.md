---
title: "SM366 - six tools cannot find the modules they load"
subtitle: "`lazysite-check.pl` died with `Can't locate Lazysite/Paths.pm` during the 0.10.13 rollout, and the deploy reported it as checks that could not be auto-repaired. The tool never ran. Five other tools have the same gap."
brand: plain
status: shipped
status-note: "SHIPPED 2026-08-18. Found in the 0.10.13 deploy log to edge - the only place it could be found, since it fails on installed trees and not in the repo. lazysite-users.pl has carried a BEGIN bootstrap since it was written; six other tools load Lazysite modules and never got one, so they work wherever something else has already put lib/ on @INC and die where nothing has. Reproduced locally against a staged install before fixing. t/lint/59 asserts the property rather than the six files, and checks the bootstrap runs BEFORE the load it exists for - which a plain presence check cannot see."
---

# What the deploy printed

```
==> verifying install (permissions + health, auto-repair)
Can't locate Lazysite/Paths.pm in @INC (you may need to install the
Lazysite::Paths module) (@INC contains: /etc/perl ...) at
/home/ispadmin/web/edge.explore.lazysite.io/tools/lazysite-check.pl line 171.
  (some checks could not be auto-repaired - see above)
```

**The second line is the defect.** A script that could not START was reported as
checks that could not be REPAIRED. An operator reading that concludes their site
has problems the tooling cannot fix. It has none - the health tool never ran.

That is the shape of SM283, SM296, SM306, SM311, SM313, SM315, SM317, SM322,
SM329, SM337, SM340, SM344, SM356 and SM365: a control reporting on work it did
not do. Here it is the health checker itself, which is the one tool whose whole
job is to tell an operator the truth about their site.

# Why it survived this long

`tools/lazysite-users.pl` has always carried a `BEGIN` block that locates `lib/`
relative to the script and falls back to the system `@INC` for package installs.
Six tools load Lazysite modules and never got one:

```datatable
columns: Tool | Lazysite loads
widths: X | 3cm
bold: 1
tone: medium
---
`tools/lazysite-acl.pl` | 5
`tools/lazysite-check.pl` | 4
`tools/lazysite-apache-vhost.pl` | 1
`tools/lazysite-cli.pl` | 1
`tools/lazysite-nginx-vhost.pl` | 1
`tools/lazysite-server.pl` | 1
---
```

They work when something else has already put `lib/` on `@INC` - run from the
repo, or through a wrapper that exports `PERL5LIB` - and die where nothing has.
That is every tarball and Hestia install, which is how the fleet runs.

**And it fails inconsistently**, which is why no gate caught it: in the same
deploy log, `lazysite-acl.pl` ran correctly minutes later, because the deploy
script sets things up for some invocations and not others. A defect that appears
in one line of a long successful log and not in the next is one nobody goes
looking for.

# What could not have found it

Not the suite: every test runs from the repo with `lib/` already on `@INC`.
Not the tarball install test: it installs and verifies the manifest, and does
not run each tool from where it landed. Not a code review: the missing thing is
absent, and absence in one file among nineteen reads as normal.

It took a deploy to a real host, and it was one line above a summary that said
`Updated 1/1 site(s)`.

# Verification

- Every tool under `tools/` that loads a Lazysite module carries the bootstrap.
- The bootstrap appears before the first load, not merely somewhere in the file.
- `lazysite-check.pl` runs from a staged install with no `PERL5LIB` set and
  produces a health report rather than a missing-module error.

# Related

[[SM293]] (which added the `require Lazysite::Paths` that exposed this),
and the 0.10.13 rollout log.
