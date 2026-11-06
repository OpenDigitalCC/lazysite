---
id: SM1321
title: "SM1321: the bad-URL blocker spares the site's own files and exempt addresses"
subtitle: "The blocker counted a site's own vendor/ assets as scanner probes, and behind a front proxy every visitor was 127.0.0.1, so everyone got 403 for 1 h 44 min. A path that resolves to a file the site has is never counted now, loopback is always exempt, and bad_url_exempt names address profiles whose addresses are exempt too."
brand: plain
standard-margins: true
status: shipped
raised: 2026-11-04
raised-by: "the release manager, ruling 48 (tmp/rulings-2026-10-22.md), Q3, on T-03 of the inbox triage (tmp/inbox-triage-2026-11-04.md): a site report, section 1; rulings 83 and 84 (Q15, Q16) on this branch's questions"
area: security
status-note: "SHIPPED (PENDING) on n742: Lazysite::BadUrl::guard skips a path site_has_file resolves to a regular file under the docroot, and an address exempt() finds: loopback always, and the address profiles bad_url_exempt names (none removes loopback). validate_exempt refuses a bad value at save. t/unit/lib/98. It reads AddressProfiles (SM1343)."
---

# What was asked

Ruling 48 (Q3): "Bad-URL blocker: never count a path that resolves to an existing file;
add a bad_url_exempt address list with loopback in the default (T-03)."

Ruling 83 (Q15): "Loopback is always exempt from the bad-URL blocker; `bad_url_exempt`
adds to it; only the value `none` removes loopback."

Ruling 84 (Q16): "`bad_url_exempt` names address lists (profiles after rulings 56-57)
only, no raw addresses; loopback is built in." An unknown name is a warning at save
and in the check, never a silent skip.

The report: `vendor/` is a built-in probe pattern (`BadUrl.pm`), and it was matched
without asking whether the file was there. A theme's scripts under `/vendor/` were
counted on every page view. No address was exempt, and on a site whose front proxy
did not pass on the visitor every request came from 127.0.0.1, so the blocker refused
every visitor for 1 h 44 min.

# What shipped

- **A path to a file the site has is not counted** (`site_has_file`). The query and
  fragment go, the path is percent-decoded once, and it must be plain segments under the
  docroot. Each step is `lstat`'d from the docroot down: every folder a real folder, the
  last a regular file. So none of these counts as the site's file: a `.` or `..`
  segment (encoded or not), a symbolic link anywhere on the way, a NUL or a backslash, a
  folder, a dot name (`.env` and `.git/config` are what scanners ask for and a site
  serves none), and the engine tree under the docroot (`lazysite/`).
- **Loopback is always exempt** (127.0.0.0/8, ::1): never counted, and a block already
  on file for it is not enforced. Only the value `none` removes it.
- **`bad_url_exempt`** in lazysite.conf: a comma list of address list NAMES (SM1138;
  membership only, so a list of either kind). Their addresses are exempt as loopback
  is, in addition to it. No address or range is written in the key: an item that is
  one names no list and exempts nobody.
- **Never silent**. The plugin's Config field ("Never block") runs
  `Lazysite::BadUrl::validate_exempt` at save, which refuses by name an item that is
  not a list name (an address among them), a name the store does not hold, and `none`
  beside names. `Lazysite::Auth::AddressRefs` reads every item as a list name, so
  `lazysite check` warns about one the store lacks and the users tool will not delete
  a list the key names. At a request an unknown name is logged once (AddressLists).
- The exemption is asked only when it changes the answer (an address on file, or a probe
  about to be counted), so an ordinary request costs what it did. An unreadable list
  store exempts nobody but loopback.
- The blocker touches address lists in `Lazysite::BadUrl` (`exempt_names`, `exempt`,
  `validate_exempt`) and AddressRefs' line for the key, so the rename to address
  profiles (rulings 56-58) changes those.

# Tests

- **t/unit/lib/98** (new):
  - the resolver's cases (a real vendor file, with a query and percent-encoded; a
    missing one; a folder; `..` and `.` segments, encoded too; a link to a file and a
    file through a linked folder; a dot name; the engine tree; a backslash);
  - through the guard at threshold 1: a real vendor asset is neither counted nor
    blocked, a missing vendor path and a `..` onto a real file block;
  - loopback: 127.0.0.1, 127.5.5.5 and ::1 are never counted, loopback in the block
    store is served, an empty key and a key naming a list both keep it exempt, and
    `none` (any case) restores the block and the counting; `exempt_names` for each
    shape;
  - lists: an address in a named allow list and in a named deny list is not counted,
    an address in neither is, an address written in the key exempts nobody, an
    unknown name exempts nobody;
  - the validator accepts names that exist, empty and `none`, and refuses an address,
    an unknown name (naming only it) and `none` beside names; the descriptor names it,
    and a real `action_plugin_save` refuses an address and accepts a list;
  - AddressRefs reports every item but `none` as a list name.
- t/integration/296 probes from 127.0.0.1 through the dev server, so it sets
  `bad_url_exempt: none`.

Sabotage, each run against the test: the file check removed from the guard fails 3;
the exemption removed fails 15; dot segments let through the resolver fails 5; a named
list replacing loopback fails 4; `none` keeping loopback fails 3; an address in the key
honoured fails 1; the descriptor without its validator fails 3; an unknown name passing
the validator fails 1; AddressRefs skipping an address item fails 1.

# Not done

- The IPv4-mapped loopback (`::ffff:127.0.0.1`) is not built in: the ruling named
  127.0.0.0/8 and ::1. A front end that hands mapped addresses over puts them in a list.
- A path is resolved against the docroot the guard is given. A file in the private
  store is not looked for.
- A hand block of an exempt address (SM704) is still written, and is not enforced while
  the address is exempt. The manager does not warn about it.
