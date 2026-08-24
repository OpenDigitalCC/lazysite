---
title: "SM245 - Briefs move out of band, into an optional plugin"
subtitle: "The sidecar FILE is the problem, not the feature. Hold briefs in a store the plugin owns, reached over the API, MCP and the manager - and the render path stops needing to know briefs exist at all."
brand: plain
status: shipped
status-note: "SHIPPED 0.10.29, with THREE RECORDED DEVIATIONS from the letter of this filing, each for a stated reason. (1) THE EXTENSION-LEVEL DENIES STAY - the processor still 404s *.brief and skips it when indexing, and every front-door template deny and its lints stand. Deployed sites carry unmigrated sidecars, and t/integration/35 records that the processor rule is what keeps a stray sidecar unserved once the engine is in the static path; removing it would reopen the SM073 leak mid-fleet. These rules are about the EXTENSION, cost nothing, and outlive the feature as legacy-file protection - t/integration/72 asserts a stray sidecar still answers 404. (2) The Files-page affordance is a single Brief button using window.prompt for the append - an interim recorded here, and SM502 U-4 modal rework is where it becomes a real editor. (3) Move re-keying takes the filing's own tolerable-interim: a moved file's store entry stays under the old path until a reconcile adopts it. WHAT SHIPPED WHOLE: plugins/briefs.pl (contract, born disabled) owning a store at lazysite/briefs/<content-path>; brief-read / brief-append / briefs-migrate on the control API and read_brief / append_brief over MCP, all under manage_content, twins recorded in the parity lints and the generated reference; the idempotent migration whose hard rule - never remove a sidecar that was not imported - is held by test against an unreadable sidecar; and the ENGINE FORGETTING: listing metadata (is_brief/has_brief), move/copy/url-convert carriage, the private-store companion moves in Files.pm AND the DAV ACL-sync, and the MCP move_file description all no longer know briefs exist. FIELD NOTE: the sites agent authors briefs as sidecars over WebDAV today; that surface becomes inert files (denied, unindexed) - they are to be told the replacement is read_brief/append_brief, and existing sidecars import via the migration. ORIGINAL NOTE: Raised by the operator 2026-08-08 as 'move .brief to a plugin', then redirected the same day: stop using sidecar files and hold briefs out of band, still bound to the file they describe. That redirection dissolves both hard problems the first draft identified - the engine no longer needs a safety rule for a disabled plugin, and move/copy/convert no longer carry anything. SM073 shipped briefs in 0.4.0; this does not remove them."
---

# SM245 - briefs move out of band

## Why

SM073 (0.4.0) gave every meaningful file a sidecar: `<file>.brief`, an
append-only record of why the file exists and what each edit changed. The record
is worth keeping. **The sidecar file is not.**

Because a brief is a file in the content tree, the engine has to know briefs
exist in order to keep them from behaving like content:

| Where | Rule | Why it exists |
|---|---|---|
| `lazysite-processor.pl` ~1249 | Refuse to serve `*.brief` | It is in the content tree, so it would otherwise be public |
| `lazysite-processor.pl` ~3913 | Skip `*.brief` when indexing | Same - it would otherwise reach sitemap / llms / feeds |
| `Manager/Files.pm` | Mark sidecars, report `has_brief` | It appears in listings as a file |
| `Manager/Files.pm` | Carry on move, copy, and url-to-md convert | It must follow its file or it orphans |
| `lazysite-mcp.pl` | Exclude `*.md.brief` from the `.md` scan | It looks like a page |

Every one of those is a consequence of the storage choice. None is a consequence
of the feature. A brief does not need to be a file: it is never edited directly,
it is never served, and everything that reads or writes it goes through the API,
MCP or the manager - all of which can reach a store just as easily as a path.

## What changes

**The plugin owns a brief store, outside the content tree**, keyed by the content
path it describes. `lazysite/briefs/` is the natural home - engine-owned,
DAV-blocklisted and never served, the same shape as the submissions store.

Access stays exactly where it is today: read and write over the control API and
MCP, and the manager showing a file's brief beside the file. The binding to the
file is preserved; only the storage moves.

### What this removes

This is the point of the redirection, and it is worth being explicit about how
much falls away:

- **The processor stops knowing briefs exist.** Both rules go. Not moved into
  the plugin - *deleted*, because there is nothing in the content tree to serve
  or to index.
- **The first draft's hard problem dissolves.** That draft had to keep
  "never served" in the engine unconditionally, because a site that disabled the
  plugin must not start serving the `.brief` files it already had. With no files,
  disabling the plugin cannot expose anything. The asymmetry disappears rather
  than being managed.
- **Move, copy and convert stop carrying anything.** A move re-keys an entry
  instead of renaming a second file. And the failure mode softens from *a private
  file left somewhere unexpected* to *an orphaned record* - untidy, not a
  disclosure. The open decision in the first draft is answered by the storage
  change.
- **The files app stops filtering.** No sidecar rows to recognise, no
  `has_brief` derived from a stat on a neighbouring path.

The plugin boundary becomes real: with sidecars, the engine had to know about
briefs in order to protect them. Out of band, it does not know they exist.

## What to build

**The store.** One entry per content path, append-only, under `lazysite/briefs/`.
Per-path entries rather than one shared file, so two authors briefing two
different pages never contend.

**The read/write surface.** Control-API actions and MCP tools to read a path's
brief and append to it, plus the manager's existing brief affordance repointed at
them. Gated by `manage_content` - a brief is authoring intent about a content
file, and anyone who may edit the file may record why.

**Re-keying on move.** When a content file moves, its brief should follow. This
is the one place the plugin needs to hear about an engine operation. If no hook
exists, an orphaned entry is a tolerable interim - it is invisible rather than
harmful - and a reconcile pass can adopt or prune it.

**Migration.** Existing sites have `.brief` files. Import each into the store,
then remove the sidecar. Must be idempotent, and must never delete a sidecar it
did not successfully import. This is the first real migration briefs have needed,
and it is the main risk in the whole request.

## Back-compat and enablement

The plugin ships **enabled on upgrade for any site that already has at least one
brief** (detectable before migration, from the sidecars themselves) and disabled
for everyone else. A site that never used briefs loses a feature it never used
and gains nothing to configure.

## Verification

- The processor contains no `.brief` handling, and the tests that covered those
  two rules are removed with them rather than left asserting dead behaviour.
- A site with the plugin disabled has no brief surface anywhere - no `has_brief`,
  no manager affordance, no tool descriptions promising brief handling.
- With the plugin enabled, reading and appending work over the API, MCP and the
  manager, bound to the same files as before.
- Migration imports every existing sidecar, removes only what it imported, and
  running it twice changes nothing.
- Moving a content file keeps its brief reachable, or leaves an entry that the
  reconcile pass resolves - and in neither case is anything served.

## Not in scope

- Removing briefs as a feature, or changing the append-only discipline.
- Editing a brief as a file. That affordance goes with the sidecars, and nothing
  used it - the API, MCP and manager are how briefs are written.
- A general post-operation plugin hook. Wanted for re-keying, but an orphaned
  entry is survivable, so this request does not block on it.
