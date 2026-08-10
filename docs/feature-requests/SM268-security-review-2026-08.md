---
title: "SM268 - Adversarial security review, August 2026: findings and disposition"
subtitle: "Four independent reviews of the pre-release tree found 26 reproduced defects, including three critical. This is the register: what was found, what is fixed, and what is not."
brand: plain
status: partial
status-note: "OPEN 2026-08-09. Four adversarial reviews were run against main plus the unmerged SM195 branch, as a pre-release gate on 0.10.5. 26 findings, 3 CRITICAL and 9 HIGH, every one reproduced by its reviewer. THE RELEASE IS BLOCKED until at least the criticals and highs are closed. Full reports (2,048 lines, with reproductions) are in tmp/security-review/ - this filing is the register and the disposition, not a copy. Findings are being closed in severity order; each closed one carries a regression test named here. NOTE the reviews ran against MAIN, so anything on an unmerged branch (SM181's draft policy, SM223's dev-server fix) was correctly reported absent - those are marked ARTEFACT below rather than fixed."
---

# SM268 - adversarial security review, August 2026

## Why this exists

Before releasing 0.10.5 the operator asked for each component to be attacked by
an independent reviewer that knew the source. Four ran in parallel, each with a
throwaway instance, each told to prove findings rather than assert them and to
record what **held** as well as what broke.

They found 26 defects. Three are critical, nine are high, and every one was
reproduced. Several are in code that shipped long ago; several are in the work
of the same week, including a fix that did not work.

This filing is the register. The reports themselves - with the exact
reproduction for every finding - are:

- `tmp/security-review/01-acl-read-path.md` (583 lines)
- `tmp/security-review/02-capability-model.md` (427 lines)
- `tmp/security-review/03-installer-and-artefacts.md` (592 lines)
- `tmp/security-review/04-authoring-surfaces.md` (446 lines)

## The result that matters most

**A fix from this week did not work, and the test said it did.** SM195 added a
capability ceiling; the manager injected the actor only when `!_is_operator()`,
and `Acl::_is_operator` returns true for anyone holding `manage_users` - exactly
the population the ceiling bounds. So the ceiling never ran on the surface that
could reach it, while `t/unit/users/23` passed because it drives the users tool
directly and supplies the actor itself.

That pattern - a guard that exists at one layer and is never reached from the
layer that matters - is the same shape as `runtime_files` being declared, read,
and never carried. It is worth naming as a class, because the suite cannot see
it: both halves are individually correct.

## What held

Recorded because a register of failures alone misrepresents the system:

- `validate_path` and **every** caller. Symlinks, absolute paths, encoded
  separators, a superset-sibling docroot and traversal were all refused. The
  SEC-2026-07 F1 fix is sound and load-bearing.
- **All of WebDAV**, including MOVE/COPY destinations, which are put through the
  full authorise chain after decoding. It is the strictest of the three
  authoring surfaces and is the model the others should follow.
- The **token/cookie channel separation**, the CORS refusal, and the `%MUTATING`
  CSRF coverage.
- **Filesystem-path disclosure**: 56 MCP invocations, valid and error-triggering,
  produced zero leaks.
- SM195's own ceiling logic, operator-only `grantable`, and unknown-capability
  rejection - all correct; they were simply unreachable.

## Findings register

Severity is the reviewer's. Status is mine.

### Critical

| # | Finding | Source | Status |
|---|---|---|---|
| C1 | An account named `local` **is** the operator. `local` is the CLI sentinel in both layers and nothing reserves the name; a `create_sub_users` delegate created one and it granted itself everything. | 02-1 | FIXED |
| C2 | A site package can carry the auth store and session secret. `path_is_reserved` compares literally, so `./lazysite` slips past and a "no secrets" export contains `users`, `acls.json` and `.secret`. | 03-F1 | FIXED |
| C3 | `--exclude=./lazysite` does not match a member named `lazysite/auth/users`, so the M-TAR-AUTH guard is inert and an uploaded tarball restore overwrites the auth store. | 03-F2 | FIXED |

### High

| # | Finding | Source | Status |
|---|---|---|---|
| H1 | `form-submissions&file=` reads any `.jsonl` under the docroot - proven to return `lazysite/auth/sessions.jsonl` (operator usernames, IPs, UAs, session ids) and another tenant's leads, to a `read_submissions` token. | 04-F2 | FIXED |
| H2 | `create_page` / `delete_page` / `rename_page` are not scope-confined: the gate inspects `path`/`to`/`from`, the tools use `slug`/`old`/`new`. | 04-F1 | FIXED |
| H3 | Folder ACL scope exists only in the processor's copy, so `Acl::_acl_allows` grants read **and write** inside a "protected section" over manager, MCP and WebDAV. | 01-M1 | FIXED |
| H4 | `read_file`/`write_file` reach the submission store and `nav.conf`, defeating `read_submissions`, `manage_forms` and `manage_nav` - refused by WebDAV, so a cross-plane inconsistency. | 04-F3 | OPEN |
| H5 | The installer follows symlinks on every write and every mode change; five attacks landed including `chmod 2775` onto an arbitrary file. | 03-F3 | FIXED |
| H6 | `install.pl --restore` lets the tarball choose absolute destinations. | 03-F4 | FIXED |
| H7 | `create_backup`'s `.backup-list-$$` is a predictable name in a group-writable directory. | 03-F5 | FIXED |
| H8 | The SM195 ceiling guards one verb; `group-add`, `group-nest`, `token`, `claim-create` and others reach the same escalation. | 02-3 | FIXED |
| H9 | Stripping `ui`/`manage_users` from every group flips the site to unsecured, where an anonymous caller is the operator. | 02-4 | FIXED |
| H10 | An owner-only ACL entry inside a gated folder republishes the file - and `copy_file` writes exactly that entry. | 01-H1 | FIXED |
| H11 | A `.url` page inside a gated section is served with no ACL check (the gate is inside `if (@md_stat)`). | 01-H2 | FIXED |
| H12 | An unreadable or malformed `acls.json` fails open, silently. | 01-H3 | FIXED |
| H13 | Gated page content leaks through `scan:` listings and `/search-index`, cached `public, max-age=3600`. | 01-H4 | OPEN |
| H14 | A section's own landing page (`<section>.md`) is not covered by the folder key. | 01-H5 | FIXED |
| H15 | The generated multi-domain rewrites serve per-domain files directly, bypassing SM223. Proven against real Apache. | 01-H6 | OPEN |
| H16 | `--restore-full` omits `--no-same-permissions`, so as root it restores setuid bits. | 03-F6 | FIXED |

### Medium and low

Recorded in the reports; not reproduced here. In summary: `grantable` ignores
group nesting while held capabilities follow it (02-5); the permissions grid has
the same blind spot (02-6); operator status is decided from a header on one path
and the store on another (02-7); `search_files` greps inside `lazysite/` (04-F4);
`action_list` has no blocklist and accepts `..` (04-F5); `delete_theme`'s creator
restriction is forgeable via the theme's own `theme.json` (04-F6); the model has
no verifier for `install_dirs` and an upgrade does not repair the incident SM246
was written for (03-F7); `{DOCROOT}/..` can never match (03-F8); the `-2`
disambiguator is sequential-only (03-F9); the `.sha256` is displayed but never
verified (03-F10); manager backups have no retention or delete (03-F11);
`content_root: .` makes `package_create` copy itself (03-F12); ACL keys are
docroot-relative so a URL-shaped key protects nothing on a content-rooted domain
(01-M3); read-path group matching is case-sensitive and does not expand compound
groups (01-L1).

### Artefacts of reviewing `main`

Not defects. The reviews ran against `main`, and these are on unmerged branches:

- **"`draft:` is not implemented"** (01-M2). It is, on `claude/sm181-draft`, with
  `t/integration/37`. The reviewer was correct about `main`.
- The dev-server static gap is fixed on `claude/sm223-static-acl`.

## Disposition

The release is blocked. Criticals and the two verified highs are closed with
regression tests; the rest are open and tracked above. Nothing here is closed on
reasoning alone - each fix carries a test that fails without it.

**H3 is closed by making the ACL semantics one thing.** The shared `Auth::Acl`
now does the same longest-match folder resolution the processor's copy does, so a
protected section is protected on all four channels rather than only on the
anonymous read path. That was SM224's question arriving from the other direction,
and it answered itself: two implementations of one store is what produced the
gap, and there is now one rule with two call sites rather than two rules.

The same change closes H10 on both sides at once - only entries carrying a
non-empty list for the mode being decided take part in the match, so an
owner-only entry cannot beat an enclosing folder rule. That matters because
*Duplicate* in the file manager writes exactly such an entry, which means an
ordinary editing action was silently republishing files inside a gated section.

**H9 still deserves its own follow-up**, because it is a design question rather
than a bug: the unsecured-site fallback treats any authenticated user as the
operator, which is a deliberate first-run convenience that becomes a live
escalation once a delegate can *push a site into* that state by stripping
capabilities. Fixing it naively risks locking operators out of genuine first-run
sites, so it needs a decision about what "unsecured" should mean rather than a
patch.

## Fail-closed, and why

H12 changed a failure direction, which is worth stating on its own because it
can take a site down. An `acls.json` that exists but cannot be read or parsed now
**refuses** rather than serving everything. Hand-written JSON is the only
interface for a folder rule, so a stray comma is a realistic way to get there,
and the previous behaviour was indistinguishable from having no rules at all -
no WARN, no access-log flag, every protected file public.

Closed is recoverable: the site refuses loudly, the manager is unaffected because
it reads through `Auth::Acl`, and an operator can still sign in and fix the file.
Open is not recoverable - by the time anyone notices, the disclosure has already
happened.
