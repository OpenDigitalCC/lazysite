# Dimension 6 - Security - lazysite eight-dimension review

- Candidate: 0.8.0-stable (0.7.28 tree at HEAD `6780878`)
- Date: 2026-07-18
- Regime: Commercial
- Assessor: independent close-out review

## Verdict

**REFUSE** (Commercial). Both prior refusal conditions have genuinely cleared -
the STRIDE/ASVS threat model exists and is current for most of the 0.6.x
surface, and the pentest gate is now declared with an auditable, dated waiver
(ADR 0007, expiry 2026-12-31 or GA marketing, whichever first). But two named,
reproducible conditions refuse this stable candidate as it stands:

1. **A reproducible XSS / response-header-injection defect in the SM179
   multilingual code** (F6.10): a content author's / content-only WebDAV
   partner's front-matter `lang:` value reaches `<html lang="...">` and the
   `Content-Language:` header **unescaped and unconstrained**, so a
   content-only grant (explicitly not trusted to run code - `EVAL_PERL=0`, the
   SM082 content/layout split) yields stored script execution in every
   visitor's browser. This is a real security defect in new code and is the
   highest-value output of this review.
2. **The significant-change register is stale for the entire body of work since
   0.7.0** (F6.2): SM165 (a new authorisation model on the confinement spine),
   SM175 and SM179 (multilingual, which introduces F6.10) have **no** recorded
   assessment. The framework requires an auditable assessment per fired trigger
   for a Commercial stable cut; the register's newest entry is SM085, all dated
   2026-07-10.

One-line basis: the by-design security gate refuses a release with a
demonstrable injection defect in shipped code, and refuses a Commercial stable
cut whose significant-change triggers since the last stable are unassessed;
both hold here.

## Method

Assessed at HEAD `6780878` (`git status --short` clean; tree = the 0.7.28
release commit). Framework: `/srv/projects/toolchain-development/TOOLCHAIN.md`
Dimension 6 detail (STRIDE/ASVS, strict SBOM gate, secrets scan, CVE, the
pentest gate with its posture table, `pentest:` block, refusal conditions and
significant-change triggers). Prior review:
`docs/review/2026-07-10-eight-dimension/dimension-6-security.md` (REFUSE ×2).
Commands and inspection:

- `perl -c` on the four new/changed modules -
  `lib/Lazysite/Auth/DomainAccess.pm`, `lib/Lazysite/Auth/Settings.pm`,
  `lib/Lazysite/I18n.pm`, `lib/Lazysite/Lang.pm` - all "syntax OK".
- Mechanical gates run for real at this tree:
  `prove -l t/lint/03-secrets.t t/lint/12-vhost-hardening.t` -> 31 tests, PASS.
  Strict SBOM gate exactly as `tools/release.sh` invokes it:
  `perl tools/build-manifest.pl --staged . ... --version 0.7.28` (209 files)
  then `perl tools/manifest-to-sbom.pl --strict ... --version 0.7.28 --staged .`
  -> **249 components, exit 0** (nothing written into the repo).
- Guarantee / auth tests: `t/unit/lib/16-audit-guarantee.t`,
  `t/unit/lib/18-git-guarantee.t`, `t/unit/auth/12-session-registry.t`,
  `t/unit/lib/20-domain-access.t`, `t/integration/23-layout-strings.t` - all
  PASS standalone.
- **Full-suite caveat (belongs to Dimension 3, noted here because I ran it):**
  `perl t/run-all.t` reports **3 failing files of 231** -
  `t/unit/dav/05-copy-move.t`, `t/unit/manager/13-theme-pristine-backup.t`,
  `t/unit/manager/37-theme-delete-domains.t`. **All three PASS when run
  standalone** (verified individually), so these are order-dependent
  test-isolation failures (shared docroot / git state bleeding between the
  theme/dav/domains tests inside the aggregate process), not product
  regressions and not security behaviours. This does not move the D6 verdict -
  no security control is among the failing assertions - but the premise "full
  suite passes clean" is not currently true of the aggregate runner, which is a
  Dimension 3 concern to resolve before the stable cut.
- `command -v gitleaks` / `command -v debsecan` - still not installed.
- Read: `docs/SECURITY.md` (threat model + significant-change register),
  `docs/adr/0007-pentest-deferral.md`, `docs/adr/0008-stable-compatibility-freeze.md`,
  `docs/POLICY.md`, `docs/architecture/security.md`.
- Source inspection of the NEW surface: `lib/Lazysite/Auth/DomainAccess.pm`
  (the SM165 confinement spine), `Auth/Settings.pm` `resolve_user_scopes` /
  `resolve_home_domain`, `lib/Lazysite/I18n.pm`, `lib/Lazysite/Lang.pm`,
  the processor's `page_lang` / `site_lang` / `_chrome_lang` / `_chrome`
  paths and the FALLBACK layout, the front-matter parser
  `parse_yaml_front_matter` + `strip_tt_directives`, the 404 fallback,
  `lazysite-manager-api.pl action_lang_status`, and the conf-mtime cache key.
- Two reproductions written to scratch (not in the repo) - see F6.10 and F6.3.

## Findings

### F6.10 - SM179 `lang` reaches `<html lang>` and `Content-Language` unescaped: stored XSS + response-header injection (REFUSE - new defect)

**This is a real security defect in code new since 0.7.0.** The root cause is
that the *page* language is never constrained to a language-code alphabet,
whereas the *site* language is.

Data path (all in `lazysite-processor.pl`):

- front matter is parsed at `parse_yaml_front_matter` (line ~2110): scalar
  `key: value` pairs are stored after `strip_tt_directives` (line 2118) and a
  trailing-whitespace strip. `strip_tt_directives` (line 3060) removes only
  `[%` and `%]`; it does **not** touch `"`, `<`, `>`, `\r`. So `$meta{lang}`
  keeps any HTML metacharacters and any embedded CR.
- `my $page_lang = $meta->{lang} || $site_lang;` (line 3995) - **no
  sanitisation** (contrast `_chrome_lang`, line 1847, which does
  `$lang =~ s/[^A-Za-z-]//g` for the *site* language on the auth/403/404
  chrome path).
- `$page_lang` is placed raw into the stash as `page_lang` (line 4049). The
  SEC-2026-07 (H5) block immediately above (lines 4012-4020) escapes
  `page_title` / `page_subtitle` / `page_author` "at the single point they
  enter the stash, so EVERY layout ... emits them safely even when it
  interpolates them without a `| html` filter" - **`page_lang` was omitted from
  that exact protection.**
- the bundled FALLBACK layout emits `<html lang="[% page_lang || 'en' %]">`
  (line 151) with no `| html` filter. Template Toolkit has no auto-escape
  (`Template->new` is called with `EVAL_PERL => 0` but no `FILTERS`/AUTO_ESCAPE
  that would HTML-encode variables), so the raw value lands in the attribute.
- separately, `$RESPONSE_LANG = $page_lang` (line 3996) is emitted as
  `print "Content-Language: $RESPONSE_LANG\n"` (line 4917) with no CR/LF strip.

**Reproduction (HTML XSS), run against the real render path:**

```perl
# front-matter lang value, author/partner controlled:
my $page_lang = 'en"><script>alert(document.domain)</script>';
# processor FALLBACK layout fragment, real TT with EVAL_PERL=0:
$tt->process(\'<html lang="[% page_lang || \'en\' %]">',
             { page_lang => $page_lang }, \$out);
# =>  <html lang="en"><script>alert(document.domain)</script>">
```

Output observed:
`<html lang="en"><script>alert(document.domain)</script>">` - the script
element is live in the served page.

**Reproduction (response-header injection), through the front-matter parser:**

```perl
my $yaml = "title: Hi\r\nlang: en\rSet-Cookie: x=1\r\n";
# parse_yaml_front_matter scalar loop, [^\n]+ captures the CR and the rest:
# $meta{lang} => "en\rSet-Cookie: x=1"   (trailing-\s strip does not remove it)
# => header:  Content-Language: en<CR>Set-Cookie: x=1
```

The `^(\w+)\s*:\s*([^\n]+)$` scalar regex admits a bare CR into the value, and
`s/\s+\z//` only trims a *trailing* run, so the injected header line survives to
the `Content-Language:` emission.

**The conf entry point was guarded; the front-matter one was missed.** The
developers clearly recognised the risk for the *site* language: `domain-set` /
`domain-add` validate a conf `lang:` to `^[A-Za-z]+(?:-[A-Za-z0-9]+)*\z` before
it lands (`lib/Lazysite/Manager/Domains.pm` 323-329, comment: "it lands in
`<html lang>` and names the i18n override file"), and `_chrome_lang` strips the
site language on the chrome path. But the **page** front-matter `lang:` reaches
`<html lang>` through a completely different door - a raw `.md` file written by
a content partner, parsed by `parse_yaml_front_matter`, never passing through
`domain-set` - and that door has no equivalent constraint. The guard is on the
key the developers were thinking about; the vulnerable path is the one they
were not.

**Why this refuses (impact).** Front matter is written by content authors,
including a **content-only** WebDAV / control-API / MCP partner (the
`capability-map.md` shows `manage_content` grants WebDAV write across the
content namespace and `create_page` / `write_file` over MCP - all distinct from
`manage_layouts`). The entire
point of `EVAL_PERL=0` and the SM082 content-vs-layout capability split is that
a content-write grant must **not** reach code execution. The rendered page is
served to anonymous visitors. So a partner holding only `manage_content` (no
`manage_layouts`) escalates a content write into script running in every
visitor's browser - and, via the header vector, into response splitting /
cookie setting. This crosses trust boundary 3 (partner) into the browser of
trust boundary 1 (anonymous visitor), defeating the boundary the threat model
names as the design's core guarantee. Severity: high; the fix is small.

**Blast radius across layouts.** The defect is not confined to the FALLBACK
layout: any bundled or library layout that renders `[% page_lang %]` /
`[% site_lang %]` in the `<html lang>` attribute (the documented, expected
pattern - and exactly what `t/integration/23-layout-strings.t` line 23 writes:
`<html lang="[% page_lang %]">`) inherits it. Because layouts are third-party
and uneditable by design, the H5 comment's own logic applies: the escape must
happen at the stash, not in each layout.

**Existing test gives false comfort.** `t/integration/23-layout-strings.t`
exercises the vulnerable pattern but asserts only functional string overlay -
it does **not** assert that a hostile `page_lang` is neutralised, so the gate
did not catch this.

**Fix (effort S, one line each).** Constrain both at the stash, mirroring
`_chrome_lang`: `$page_lang =~ s/[^A-Za-z-]//g; $page_lang ||= 'en';` before
line 4049, and the same for `$site_lang`/`$RESPONSE_LANG`; add a regression
case to `23-layout-strings.t` asserting a `lang: en"><script>` front matter
renders inert. A BCP-47 tag is `[A-Za-z-]` only, so the constraint loses no
legitimate value. Classification: **REFUSE** - a demonstrable injection defect
in shipped code is the archetypal by-design security refusal.

### F6.2 - Significant-change register stale for all work since 0.7.0 (REFUSE, recurrence)

The register in `docs/SECURITY.md` ("Significant-change assessments") is the
auditable record the framework requires - and ADR 0007 makes it load-bearing:
"Significant-change triggers are live from this date: each fired trigger gets a
recorded assessment". Every entry is dated 2026-07-10; the newest change
assessed is SM085. The work the 0.8.0-stable candidate promotes from edge
(the release commit names it: "multilingual completion + cache correctness +
domains/manager UX"; ADR 0008 names SM165/SM175/SM179 explicitly) has **no**
entry:

```datatable
columns: Change since 0.7.0 | Framework trigger it matches | Assessed?
widths: 5.4cm | X | 2cm
bold: 1
tone: medium
text: 3
---
SM165 domain access model | new authorisation model on the confinement spine (auth/authz change) | NO
SM175 rename-following content history | change to the versioned-content write/read path | NO
SM179 multilingual (P1-P8) | new processing/rendering surface; introduces F6.10 | NO
```

SM165 in particular is exactly the class the register exists to catch: it
replaces the SM155 per-group `dav_scope` with a domain-owned allow/lock model
that every confinement check now depends on. Its logic is sound (F6.4), but
"sound on inspection" is not the artefact the gate demands - the gate demands a
dated, auditable assessment, and there is none. This is the third consecutive
review to record an unassessed-trigger backlog; for a *stable* cut under a
five-year support commitment it is a refusal, not a WARN. Classification:
**REFUSE**. Fix: one dated register entry each for SM165, SM175, SM179 (the
SM179 entry must record F6.10 as not-contained until fixed); effort S.

### F6.11 - `domain-add` writes generic keys without the CRLF guard `domain-set` has: conf-line injection (WARN - new defect, `manage_domains`-gated)

The SM165/SM179 domain writer has an asymmetry between its two entry points.
`domain_set` (`lib/Lazysite/Manager/Domains.pm` 337-339) rejects any value
containing `[\r\n]` before calling `_set_line` - "Values are single-line conf
values: no newlines". `domain_add` (251-254) writes the generic presentation
keys (`site_name`, `theme`, `layout`, `nav_file`, `search_default`) through the
**same** `_set_line` with **no** CRLF check - only `content_root`, `lang` and
`lang_group` are validated in `domain_add`. `_set_line` (117-128) interpolates
the value into `alias.<host>.<key>: $value` verbatim, so a newline in the value
writes an extra conf line.

Reproduction (scratch, exercising `_set_line` as `domain_add` calls it):

```
domain-add host=good.example site_name="Foo\nalias.good.example.content_root: ../lazysite/auth"
# resulting conf gains:
#   alias.good.example.site_name: Foo
#   alias.good.example.content_root: ../lazysite/auth   <- injected, bypassing _clean_content_root
```

The injected `content_root` line never passes `_clean_content_root`'s
reserved-path / traversal check (that check runs only on the *declared*
content_root argument, not on a line smuggled through another key), so it can
point a domain's content root at `../lazysite/auth` or another reserved area -
exactly the confinement the validator exists to prevent. **Severity is bounded
by the gate:** `domain-add` requires `manage_domains`, a high-trust,
operator-adjacent capability (it already provisions directories and edits the
conf), so this is privilege *widening within an already-privileged role*, not a
low-to-high escalation - hence WARN, not REFUSE. But it is a real defect in new
code and the fix is trivial: hoist the `domain_set` CRLF guard (or apply it in
`_set_line` itself, covering both callers). Effort S. Classification: WARN.

### F6.1 - STRIDE/ASVS threat model exists; currency gap for the 0.7.x surface (WARN, was FIXED)

`docs/SECURITY.md` remains the method-structured threat model the framework
asks for: five trust boundaries, a six-category STRIDE table with control +
location + residual per row, the five priority entries, and an ASVS L1
met/open register. It is current through the 0.6.x/0.7.0-0.7.2 surface (the
register now folds in SM136/137/140/142/139 and the SM085/SM141 main-branch
work). **Gap:** it is not refreshed for the 0.7.x edge line this candidate
ships - the STRIDE assets omit the multilingual surface, and neither the
Information-disclosure nor the Tampering row mentions the `page_lang` sink
(F6.10) or the SM165 domain-owned scope source. Folding these in is small and
must accompany the F6.2 register entries. Classification: WARN (currency), not
a refusal on its own - but the F6.10 residual it is missing is itself the
refusal.

### F6.3 - SM165 domain access: confinement spine is sound (PASS)

`lib/Lazysite/Auth/DomainAccess.pm` + `Auth/Settings.pm resolve_user_scopes`
is the new authorisation core. Inspected and exercised:

- `DENY_ALL_SCOPE` is a sentinel no real path can match (`"\0sm165-locked-
  nowhere"`), so a locked user whose lock excludes every domain their groups
  allow is confined to **nothing**, never silently unconfined - the empty-list
  = unconfined convention is handled explicitly (lines 137-139).
- the sub-user ceiling `intersect_scopes` keeps the tighter of each overlapping
  pair and returns `DENY_ALL` (not empty) when scopes are disjoint (line 63),
  so a created account can never out-reach its creator, and the ceiling is
  applied at resolve time walking the `created_by` chain with a cycle guard
  (`Settings.pm` 92-99) so config drift cannot lift it.
- a non-default domain with an empty `allowed_groups` is operator-only (no
  group reaches it, line 120); the default site needs no allow.

Reproduction (scratch) confirmed each: a user locked to a domain their groups
allow is confined to that content root; an unlocked editor gets the union; a
user locked to a domain their groups do **not** allow gets `DENY_ALL`; a
disjoint creator/child ceiling gets `DENY_ALL`. Pinned by
`t/unit/lib/20-domain-access.t` (23 tests, PASS). Enforcement is unchanged from
SM151/SM155 - only the *source* of the scopes moved - so the confinement point
is not re-litigated. **One threat-model note (not a defect):** `effective_scopes`
returns empty (= unconfined, whole-site editor) when an effective domain's
`content_root` is empty; a mistyped alias `content_root:` therefore silently
unconfines that domain's editors. Worth a residual line, not a refusal.
Classification: PASS.

### F6.4 - SM179 I18n fail-closed guarantee holds; i18n file path is traversal-safe (PASS)

`lib/Lazysite/I18n.pm` meets its stated hard safety line: `chrome_string`
starts from the built-in English table and overlays the per-language file only
for a non-`en` code with a non-empty value; any miss (unknown language, missing
key, unreadable/invalid JSON, empty translation) yields the English string, so
a mis-set language can never blank a page or hide an auth-reject reason. The
overlay file path is traversal-safe: `_overlay` refuses any code not matching
`^[A-Za-z][A-Za-z-]*$` before it can name a file (line 44), so
`../../etc/passwd`-style codes never reach `open`, and the code is
`lc`-normalised into `lazysite/i18n/<lang>.json`. Interpolated `@args` are
HTML-escaped (`_esc`) - correct, since callers emit into HTML. The
`_chrome_lang` feeder (processor 1847) also strips the site language to
`[A-Za-z-]`, so the *chrome* path (403/404/auth pages) is safe - it is only the
*page* path (F6.10) that skips the same constraint. `Lazysite::Lang` reads only
conf and content, never writes, never decides confinement (its own scope line),
and its `lang_status` file walk is rooted under the docroot with `lazysite/` and
dotfiles skipped. Classification: PASS. (The XSS is not here - I18n escapes; it
is the un-sanitised `page_lang` sink in the processor, F6.10.)

### F6.5 - 404 URI-escaping fix verified; conf-mtime cache is host-scoped (PASS)

The prior latent reflected-markup vector on the bare 404 path is fixed: the
fallback now emits `_chrome('notfound.body', $uri)` (processor 4963), and
`chrome_string` HTML-escapes `$uri` via `_esc` (the code comment at 4959-4960
records it was "interpolated raw before"). Verified inert.

The conf-mtime site-vars cache (processor ~3238) is keyed on
`(conf mtime, request host)`, so a conf edit or a different Host on the next
request re-resolves - there is **no cross-host cache-poisoning angle**: host A's
resolved site-vars can never be served under host B because the host is part of
the cache signature. This is the correct durable fix for the persistent-worker
(SM142) model. Classification: PASS.

### F6.6 - Manager preview / lang_status: manager-gated; one read-over-exposure (PASS with a gap)

The manager preview shells the processor with `qx($^X \Q$processor\E ...)`
(quotemeta'd path, no shell-interpolated request data) and strips CGI headers
(`lazysite-manager-api.pl` ~1192) - manager-cookie-gated, no injection channel
in the invocation. The `lang-status` action is gated on `manage_content`
(dispatch 352 / `%need` 475) and is read-only. **Gap:** `action_lang_status`
walks **every** member root of the language group (`Lang::lang_status`) and
returns per-file path listings + coverage counts, without intersecting the
caller's SM165 resolved scopes. A `manage_content` token confined by SM165 to
one language domain therefore gets a file listing of every **sibling** domain
root in the set - a modest read-over-exposure (listings, not contents; and a
manager-cookie operator is inside the trust boundary anyway). Confine
`lang_status` to the caller's `resolve_user_scopes` when the caller is a scoped
token, or document the report as set-wide by design. Effort S. Classification:
PASS on gating, WARN-level on the scope gap.

### F6.7 - Pentest gate now declared with an auditable dated waiver (FIXED, was REFUSE)

The prior review's standing REFUSE ("pentest gate structurally absent") is
cleared. `docs/adr/0007-pentest-deferral.md` (Accepted, 2026-07-10) declares
the full `pentest:` block (required: yes; scope application + infrastructure +
hosting; annual + on-significant-change; CREST-CRT/OSCP/GPEN; third-party;
remediation SLAs; retest for critical/high) and defers the first engagement
under the one alternative the framework's letter accepts: a waiver ADR naming
the reason (pre-launch, per the holds decision), the accountable person, and an
**explicit expiry** - "before GA marketing, or 2026-12-31, whichever comes
first", non-renewable by default. This is exactly the documented-deferral-with-
expiry the gate permits. The waiver is within its window at this date
(2026-07-18 < 2026-12-31). Compensating controls are named and in force.
Classification: FIXED - the pentest refusal condition is cleared for this cut,
**provided** the significant-change assessments the same ADR mandates are
actually recorded (they are not - F6.2, which is why the ADR's own "a
not-contained finding pulls the engagement forward" clause is now triggered by
F6.10).

### F6.8 - Mechanical gates: all green (PASS)

Secrets lint + vhost-hardening: 31 tests PASS. Strict SBOM gate: **exit 0, 249
components** at 0.7.28 (up from 214 at 0.6.10 - the new multilingual/manager
work added no undeclared dependency; the by-design drift gate held through the
whole edge line). Guarantee tests (audit, git) and the auth/session and
domain-access unit tests pass. `perl -c` clean on all four new modules.
Classification: PASS.

### F6.9 - CVE check and gitleaks still absent (WARN, carried over)

Neither `debsecan` nor `gitleaks` is installed and nothing in `tools/` performs
a CVE check against the declared `debian_pkg` versions. Unchanged since
2026-07-01; a zero-risk unblock (install two Debian packages, wire two
wrappers). Not a refusal on its own, but overdue for a stable cut.
Classification: WARN.

## Prior findings - disposition

```datatable
columns: Prior finding | Was | Now
widths: 7cm | 2.2cm | X
bold: 1
tone: medium
text: 3
---
F6.1 STRIDE/ASVS threat model | FIXED (currency gap) | WARN - still current for 0.6.x; not refreshed for 0.7.x / SM179
F6.2 pentest gate absent; triggers unassessed | REFUSE | Split: gate FIXED (ADR 0007); triggers REFUSE again (SM165/175/179 unassessed)
F6.3 mechanical gates green | PASS | PASS - SBOM 249 components, exit 0; secrets + vhost green
F6.4 no CVE check / gitleaks | WARN | WARN - unchanged
F6.5 notify-xmpp.conf perms / SM140 empty-secret | WARN / PASS+gap | Cleared - Batch-1 (bdb4c86): chmod 0660 + lazysite-check probe; SM140 keyed on persistent random salt
New: SM165 confinement spine | - | PASS (F6.3 here)
New: SM179 page_lang sink | - | REFUSE (F6.10) - stored XSS + header injection
New: SM165/179 domain-add conf injection | - | WARN (F6.11) - CRLF guard missing on one entry point
```

## Recommendations

Ranked; effort S/M/L; each names the framework gate it satisfies. Items 1-2
clear the two refusal conditions.

1. **Fix F6.10 - constrain `page_lang` and `site_lang`/`$RESPONSE_LANG` at the
   stash** (`$lang =~ s/[^A-Za-z-]//g` before line 4049 and before the
   `Content-Language:` emission), mirroring `_chrome_lang`; add a regression
   case to `t/integration/23-layout-strings.t` asserting a `lang: en"><script>`
   front matter renders inert and no CR reaches the header. Effort S. Clears
   the injection-defect refusal (by-design security gate).
2. **Record the significant-change assessments for SM165, SM175, SM179** - one
   dated `docs/SECURITY.md` register entry each, per ADR 0007's own mandate;
   the SM179 entry states "not contained" until item 1 lands, then flips to
   accepted. Effort S. Clears the unassessed-trigger refusal and stops the
   third-cycle recurrence.
3. **Refresh the threat model for the 0.7.x surface** (F6.1): add the
   multilingual surface and the SM165 domain-owned scope source to the assets;
   extend the Tampering / Information-disclosure rows with the `page_lang` sink
   (post-fix, as a closed control) and the F6.6 lang_status set-wide read.
   Effort S. Satisfies threat-model freshness.
4. **Fix F6.11 - apply the CRLF guard in `_set_line` (or in `domain_add`)** so
   both domain writers reject newline-bearing values; the sibling `domain_set`
   guard shows the intended behaviour. Effort S. Closes the conf-line injection
   that lets a `manage_domains` holder smuggle a reserved `content_root`.
5. **Confine `lang_status` to the caller's resolved scopes** (F6.6), or document
   it as a set-wide report by design. Effort S. Keeps SM165 confinement
   consistent across the read surface.
6. **Add a threat-model residual for the empty-`content_root` unconfine corner**
   (F6.3): a mistyped alias `content_root:` silently unconfines that domain's
   editors; consider a `lazysite-check` warning when a domain declares
   `allowed_groups`/`locked_users` but an empty `content_root`. Effort S.
7. **Install debsecan and gitleaks and wire the wrappers** (F6.9): a release-path
   CVE check keyed off `debian_pkg`, and a full-history gitleaks sweep in the
   release path. Effort S each. Satisfies "CVE check against declared
   dependency versions" and "gitleaks host-wide" - both waiting since
   2026-07-01.
