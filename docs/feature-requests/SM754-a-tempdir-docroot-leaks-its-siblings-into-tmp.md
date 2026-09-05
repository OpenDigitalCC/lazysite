---
id: SM754
title: "SM754: a test that uses a bare tempdir as a docroot leaks the docroot's siblings into /tmp"
subtitle: "The engine writes beside the docroot - the private store at <docroot>-lazysite-private, the Hestia layout's plugins/ tools/ lib/ at ../ - and File::Temp cleans only the directory it made. /tmp on the dev host holds 15,386 entries and 356 MB of them, and a leaked /tmp/plugins/stats.pl made a 'plugin not found' assertion pass for the wrong reason."
brand: plain
standard-margins: true
status: candidate
---

# What was found

Writing `t/unit/daemon/05`, an assertion that the stats plugin is reported "not
found" when no plugin exists kept finding one. The resolver's Hestia candidate is
`<docroot>/../plugins/stats.pl`; the test's docroot was a bare `tempdir()`, so
its parent was `/tmp`, and `/tmp/plugins/stats.pl` existed - left by some
earlier test whose `install.pl` populated the Hestia siblings beside ITS
tempdir docroot. `File::Temp`'s `CLEANUP` removes the directory it created and
nothing beside it.

Counting what is beside them on the dev host:

| Shape | Count | Written by |
| --- | --- | --- |
| `<tempdir>-lazysite-private` | 7,510 | the private store, a sibling of the docroot by design (t/lint/51) |
| `<tempdir>-manifest.json` / `-deps.json` / `-sbom.json` | ~3,000 each | the manifest and SBOM tools writing beside their input |
| `<tempdir>-cfg` | 2,226 | the gate-record rig (`lazysite-gaterec-*-cfg`) |
| `tmp.<random>` | 1,911 | `mktemp` from shell rigs without a trap |
| `/tmp/plugins`, `/tmp/tools`, `/tmp/lib` | 3 dirs | the Hestia layout, one level up from a tempdir docroot |

15,386 entries, 356 MB. 534 test files call `tempdir(`.

Two costs. The obvious one is the disk. The one that matters is the last row: a
leaked sibling is a fixture nobody wrote, visible to every later test that looks
one level up, and it can make an assertion pass - which is how it was found.

# What to do

1. `TestHelper::site_tempdir()` returning `<tempdir>/site` (or `.../public_html`
   for Hestia-shaped tests) so every sibling write lands INSIDE the directory
   `CLEANUP` removes. `t/unit/daemon/05` does this by hand and says why; the
   helper makes it the default.
2. A lint that refuses a test using a bare `tempdir()` as a `--docroot` or
   `$DOCROOT` - the same shape as the other "the fixture must agree with the
   reader" lints.
3. Clear the dev host's `/tmp` of the classes above once, and have the gate rig
   trap its `mktemp`.

Wide but mechanical; the 534 files do not all need converting, only the ones
whose subject writes beside the docroot, which the lint identifies.

# Related

SM666 (where it was found), t/lint/51 (the private store is a sibling by rule).
