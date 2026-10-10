---
title: "Work plan - 0.15.3"
subtitle: "The open filings after 0.15.2, sorted by what each needs next: built, ruled, reproduced, or waited for."
brand: plain
standard-margins: true
---

# How to read this

Every row is an open item in a filing, by the filing's own label. **Needs** says
what has to happen before it can be built. Sizes are the filing's where it gives
one. Rulings taken on this plan are recorded in the table at the end.

# Build queue - worked in this order (set 2026-10-07)

The release manager: "keep progressing through task list sequentially, i will run
reviews in a batch later". The developer agent works down this list without
stopping for review. Each item is one branch, stacked on the previous one,
handed off READY (`tools/handoff.sh`); the release manager lands them in a batch.
An item that needs a ruling the plan does not hold is skipped, its question is
added to the open-questions list at the end of this section, and the next item
starts.

| Q | Item | Why here | Size |
| --- | --- | --- | --- |
| Q1 | ~~A2 [[SM912]] P4~~ **already built (e765424f, 0.15.1); recorded (n253)** - an ACL fixture with an empty auth store is visible | ready, XS | XS |
| Q2 | ~~B1 [[SM939]] SC2~~ **built (n266) as ruled R1-amended** - DELETE of a non-empty collection answers 405 "delete the contents first" (R1) | ruled, S | S |
| Q3 | ~~B2 [[SM913]]~~ **built (n254)** S2 + S4 - link-shortener hosts as a stronger signal; each form's quarantine state shown (R2) | ruled, small | XS+S |
| Q4 | ~~B6 [[SM932]]~~ **built (n255)** (2) - `lazysite check` writes a known line and reports which sinks received it (R6) | ruled; Q5 shares its shape | S |
| Q5 | ~~F5 [[SM955]]~~ **built (n256)** - the XMPP test reports a bounce; every delivery failure audited (R9) | after Q4, same reporting shape | M |
| Q5a | **[[SM958]] security, found by the Q6 survey - built (n257)**: a token-gated action was open to any manager account | fixed before Q6 continues | S |
| Q5b | **[[SM959]] robustness, found by Q5a's handoff - built (n258)**: a child that exits early killed its caller (SIGPIPE) | fixed before Q6 continues | S |
| Q6 | **stage 1 built (n259)**: the manager API's ten per-action tables derive from `%ACTION`; stages 2-3 are Q13a - E5 [[SM943]] - one declaration per control-API action, the rest derived | must precede Q7/Q8, which add actions | L |
| Q7 | ~~B3 [[SM857]]~~ **built (n260)** read half - `(mine)` views of a table (R3) | after E5 | M |
| Q7a | **[[SM960]] security, found by the Q7 agent - built (n261)**: a custom auth header name was trusted from anyone | fixed before Q8 | S |
| Q8 | ~~B4 [[SM858]]~~ **built (n262)** - approve an account from the Submissions view (R4) | after E5 | M |
| Q8a | **[[SM961]] data loss, found by the Q8 agent - built (n263)**: a submission arriving during a store rewrite was lost | fixed before Q9 | S |
| Q8b | ~~[[SM962]]~~ **built (n264)** - account-approve strips a name it then uses unstripped (CLI/Users API) | reproduce, then refuse by name | S |
| Q8c | ~~[[SM963]]~~ **built (n264)** - account-approve hides a failed group placement | reproduce, then report it | S |
| Q9 | ~~F7 [[SM957]]~~ **built (n265)** - Submissions page and menu entry with an unread count; menu regrouped; Handlers off the menu (R11) | after Q8, which adds to the Submissions view | M |
| Q10 | ~~A1 [[SM906]] T3~~ **built (n267)** - a distinct "cannot tell" when the auth store is unreadable | ready | M |
| Q10a | **[[SM906]] T3 follow-up, security - built (n268)**: the processor's own copy of the manager-grant check failed open on an unreadable or corrupt group store | found by the Q10 agent | XS |
| Q11 | ~~A3 [[SM869]]~~ **built (n269); adversarial review pending** - raw and escaped query values separated, hostile-value test first; its adversarial review on its own branch (R7) | ready; last of the features so its review sees a settled tree | M |
| Q11a | **[[SM964]] security, found by the Q11 review - built (n270)**: a value that reached a page as data could become an include | fixed at once | S |
| Q11a2 | **[[SM965]] security, found by the Q11 review - built (n270)**: a reflected form value could become an include | fixed at once | XS |
| Q11b | ~~[[SM869]] adversarial review, second pass: encodings, Markdown interplay, attribute contexts, split template syntax, api: JSON (the first pass stopped early)~~ **done (n271)** - all five covered; [[SM966]], [[SM967]], [[SM968]] and [[SM969]] found and fixed | owed | M |
| Q12 | ~~E6 [[SM950]] (2)(3)~~ **built (n272)** - gate on landing; coverage reused when its inputs are unchanged | tooling; after the feature work it speeds up | M |
| Q12a | **[[SM906]] T3 users store, as ruled 2026-10-07 - built (n273)**: an unreadable account store answers cannot-tell, naming nothing | ruled | XS |
| Q12b | ~~[[SM970]] - a value used as a whole link target keeps its URL scheme~~ **built (n275) as ruled** - the `url_safe` filter, authoring docs, lint 213 | ruled 2026-10-07: option 1 with 3 | S |
| Q12c | ~~[[SM971]] release process: one generator, gate tests the material, one release commit, publish pushes main and the tag~~ **built (n276)** - tools/release-material.pl, no rehearsal, build commits and tags, handoff --stack | release manager 2026-10-08 | M |
| Q13a | ~~E5 [[SM943]] stages 2-3~~ **built (n274)** - the MCP twins and annotations from the declaration; the consistency lints reduced to one completeness check | Q7/Q8 need only stage 1 | M |
| Q13 | ~~C2 [[SM883]] - measure the 1.20-1.27x slowdown on this machine, then bisect~~ **measured (n277): the machine, not the code** - v0.14.1 is 1.01-1.03x the baseline's commit on the same host; no bisect, no code change; a 0.05 ms verify cost found at 416bdffb (SM906 T3, deliberate) | measurement, no ruling needed | S-M |
| Q14g | **[[SM974]] - built (n305)**: a stats day is a UTC day - the plugin closed a first-party UTC day at local midnight, so east of UTC its last hours never reached the day file; nineteen stats tests fixed to the same calendar (06, 09, 31 failed on main between midnight and 01:00 BST) | found by the SM944 S20 agent, 2026-10-09 | S |
| Q14a | **built (n279)**: a static work counter in the bench baseline is updated with the code that changes it (t/lint/216); the gate's refusal of main (3378 vs 3359, SM962/963) resolved | found by the gate on main after the last landing | XS |
| Q14b | **built (n285)**: the release gate runs from a git worktree; its state stays in the main checkout | found running the gate after the last landing | XS |
| Q14c | **[[SM972]] security - built (n290)**: a custom payment header name was trusted from anyone | found by the SM944 S6-S9 agent | XS |
| Q14d | **built (n294)**: the gate names a failed suite as one (markers matched whole); test 106 is robust under coverage; lint 38 reads the processor's parts | found by the gate of main, 2026-10-08 | XS |
| Q14e | **built (n300)**: test 97 keeps its stand-in generators out of a coverage run (it failed the gate's instrumented suite on main 4e9f2bb5) | found by the gate of main, 2026-10-08 | XS |
| Q14f | **[[SM973]] security - built (n303)**: a pooled worker kept serving a file after it was protected (the ACL store was read once per worker) | found by the SM944 S19 agent | XS |
| Q15a | **[[SM975]] security, ruled 2026-10-09 "no scope = no domain" - built (n310)**: a token with no scope wrote every domain (domain-set/-add/-alias-add/-remove, remap-save, site-backup-apply, MCP domain_set); scoped callers' gaps found and filed for a ruling | found by the SM944 S22 agent | S |
| Q15b | **[[SM976]] security, ruled 2026-10-09 "One rule, fix all" - built (n312)**: a confined caller (token, MCP grant, WebDAV account, scoped cookie manager) reaches only its own domains; every host- or root-addressed action on the three surfaces asks `Manager::Common::caller_may_reach_domain` (lint 218). Closed: scoped domain-add/-alias-add/-remove/content_root, MCP domain_set scope and manage_users, cookie package reach, nav on all three surfaces, listings, data-table-save's `domain:` | ruled 2026-10-09 | M |
| Q15c | **[[SM976]] rulings R1-R4, ruled 2026-10-09 - built (n314)**: R1 a domain-confined caller changes no instance-wide setting - 28 control-API actions declared `instance_wide` (config, activation, extensions, layouts library, connectors, handlers, schedules, auth secret, audit switch, blocklist, instance backups, briefs migration) and their MCP twins refused before dispatch, `create_theme` with activate, confined `theme-delete` to its own themes, instance backups hidden; lint 218 section 5 accounts for every mutating action. R2 an unbound cookie manager is unconfined on the data surface. R3 pinned by name (207). R4 the data surface asks `caller_may_reach_domain`; the table access-rule verbs and safety exports now ask reach. Three findings filed in SM976 for a ruling (domain-served theme files, forms and briefs, dropped-table exports); `bad-url-block` never ran (block() not imported) - fixed | after Q15b; ruled 2026-10-09 | M |
| Q15d | **[[SM976]] findings F1-F4, ruled 2026-10-09 - built (n315)**: F1 "Yes, any served artifact" - a confined caller writes a theme or layout only if no site serves it or only its own domains do (`served_artifact_refusal`, on the file choke point, WebDAV and the multipart upload, which also gains SM749); F2 "Confine both" - every form verb asks the pages binding the form (an unbound form is the primary's), every brief verb the page's path or the row's table, listings filtered, WebDAV form conf too; F3 "Record domain" - a safety export records its table's domain, an old one is the primary's; F4 "Activate on its domain" - `theme-activate`/`layout-activate` take `host` on the control API, `themes-list-all` names `acts_on`, the scoped manager's Appearance page binds its own domain. Lint 218 sections 6-7; t/integration/116, t/unit/manager/208, 209, t/unit/data/68 | after Q15c; ruled 2026-10-09 | M |
| Q15e | **[[SM976]] Q15d finding, ruled 2026-10-09 "Refuse new binding" - built (n316)**: no content write by a confined caller newly binds (front matter `form:`) a form it does not reach - `Manager::Common::form_bind_refusal`, judged on the form's current bindings, asked before the write by the file choke point (save, save-binary, move, copy, migrate-to-local; git-restore through save), the multipart upload, the site-package apply and WebDAV PUT/COPY/MOVE; a move or copy of a binding page is a new binding where it lands; both readings of the form (the processor's and form_bindings'). F3 old exports ruled: n315 stands, no code. Lint 218 section 8, lint 114; t/integration/117, t/unit/manager/210. Found: the walker and the processor read a page's form differently (filed in SM976) | after Q15d; ruled 2026-10-09 | S |
| Q15f | **[[SM976]] Q15e decision and findings, ruled 2026-10-09 - built (n317)**: a3686669 "Keep" (a form that exists nowhere is new; recorded only). "One reading, processor's": which form a page binds is read as the processor renders it on every rule - `Manager::Common::page_form`, a marked copy of `parse_yaml_front_matter`'s reading pinned by lint 219, asked by `form_bindings` (the 16 KB first-line reading gone), the write rule, MCP `create_form`, `validate_page` and `audit_site`; every changed case asserted (t/unit/manager/211: N1 narrows across domains, W1-W6 widen and R1-R5 narrow inside scope). "Fix: per-tool path args": each MCP tool declares `path_args`, `@PATH_ARGS` gone, replace_text's old/new are text, rename_page's stay paths; lint 91 holds every argument of every tool; t/integration/118 (every declared tool and argument still refused outside the scope). Found: create_form with an extensionless path replaces an existing page (filed in SM976) | after Q15e; ruled 2026-10-09 | S |
| Q15g | **[[SM977]] data loss, found by the Q15f agent - built (n318)**: MCP `create_form` with an extensionless path replaced the page it named with a scaffold; it now reads the file it writes, appends, adds front matter to a page with none, refuses a page it cannot read, saves with the read's mtime (t/integration/119). Other page-writing tools checked (SM977): `copy_file` overwrites an existing target, unlike the manager's copy - recommended, not changed. [[SM976]] probes: a `.url` page renders no form (not confirmed); malformed UTF-8 bytes bypass the form-binding write rule on the raw-bytes doors, and one such page makes the walker die - recorded for a ruling | found by the Q15f agent, 2026-10-09 | S |
| Q15h | **[[SM976]] / [[SM977]] Q15g findings, ruled 2026-10-09 - built (n321)**: "Refuse + walker skips": a `.md` page arriving as raw bytes (MCP `upload_file`, the multipart upload, WebDAV PUT, a site package) is refused unless it is valid UTF-8, for every caller, saying so and how to fix it (`page_bytes_refusal`, t/integration/120); a page whose reading dies binds no form and is logged (`page_form_or_none`, t/unit/manager/212). One such page also killed the processor's scan and registry walks (every page of a site with a `scan:` source answered 500) and MCP list_pages/audit_site/form_list: same rule (t/unit/processor/93, t/unit/mcp/29). "Refuse existing target": `copy_file` asks `action_copy`'s check (t/unit/mcp/30). "Pin with a test": a `.url` page renders no form (t/unit/processor/94). Found: MCP `search_files` returns no body when a page in its base is not UTF-8 - ruled, built as Q15i (n322) | after Q15g; ruled 2026-10-09 | S |
| Q15i | **[[SM976]] Q15h finding, ruled 2026-10-09 "Same rule" - built (n322)**: MCP `search_files` leaves out a file that is not valid UTF-8, logged, and answers for the rest (t/unit/mcp/29). Every page walk probed with one such page (inventory with file:line in SM976): two more broke and take the same rule - the processor's `resolve_scan` excerpt, which reads the body (every page listing the scan answered 500; t/unit/processor/93), and `lazysite-validate` over many pages (died, printing nothing; now reports the file as unreadable, t/tools/82). `lazysite-check`, the link-audit plugin, `rename_page`'s link rewrite and the raw-byte readers survive, unchanged. Found: `read_page` on such a page answers no body (one page, not a walk); the Q15g row restored | after Q15h; ruled 2026-10-09 | S |
| Q15j | **[[SM976]] Q15i findings, ruled 2026-10-10 - built (n325)**: "Exit 1": n322's validator stands (recorded). "Fix both": (a) an MCP single-page read of a page that is not UTF-8 answers as one it cannot read - `page-encoding-refused`, the offset, how to fix it (`page_read_refusal`) - on `read_page`, `read_file`, `view_version`, `read_brief`, `preview_page` (each answered no body), `validate_page`, `create_form` ("Tool error") and `preview_public_page`; `page_status`, `get_permissions`, `list_versions`, `invalidate_cache` already answered (t/unit/mcp/31). (b) `_each_page` says when it stops at 1,000 pages: `list_pages`, `audit_site` and `rename_page`'s link rewrite answer `truncated` and `page_cap`, descriptions say so; `form_list` walks uncapped (t/unit/mcp/32). Found: `restore_version` writes a non-UTF-8 version back as is; `read_nav` "Tool error" on a non-UTF-8 nav.conf | after Q15i; ruled 2026-10-10 | S |
| Q15k | **[[SM976]] Q15j findings, ruled 2026-10-10 "Fix both" - built (n327)**: (1) a restore of a recorded version that is not UTF-8 - MCP `restore_version` and the control API's `git-restore`, one `action_git_restore`, both wrote it back as it was - is refused with the encoding error (`page-encoding-refused`, the offset, how to fix it) and the file left as it is, no restore recorded; (2) MCP `read_nav` ("Tool error") and the API's `nav-read` (no body) on a `nav.conf` that is not UTF-8 answer the encoding error naming the file (t/integration/121) | after Q15j; ruled 2026-10-10 | S |
| Q14h | **built (n308)**: lints 25 and 217 judge their exclusions on the path below the checkout - under a tmp/ path (the gate's worktree, the release staging clone) 217 scanned nothing and failed the gate of main 892951a3, and 25 passed having read 6 of 132 files | found by the gate of main, 2026-10-09 | XS |
| Q14 | E9 [[SM944]] - split the processor and the manager API, one area per branch. **Planned** (SM944 § Plan, rows S1-S34: S1-S20 the processor's parts, S21-S34 the manager API's modules); **S1 (n278), S2 (n280), S3 (n281), S4 (n282), S5 (n283), S6 (n286), S7 (n287), S8 (n288), S9 (n289), S10 (n291), S11 (n292), S12 (n293), S13 (n295), S14 (n296), S15 (n297), S16 (n298), S17 (n299), S18 (n301), S19 (n302), S20 (n304), S21 (n306), S22 (n307), S22b (n319), S23 (n320), S23b (n323), S24 (n324), S25 (n328), S26 (n329), S27 (n330), S28 (n331), S29 (n337), S30 (n335) built** - the front-matter parser; the shared state as `our`; oEmbed; the URL remapper; content components; the content-type cache; the payment and preview gates; the access log; the front door; include and Markdown; forms; output and headers; the request address and host; sources and site vars (the memo stays in the script); scan and registries; the template render; layout, theme and injection; the page pipeline (`_lazy_lib` and the content-roots memo stay in the script); the ACL, group and domain copies; the auth gate (the trust gate stays in the script) - the processor's rows are complete; the manager request context in Manager::Common, fail-closed until a request sets it (ruled 2026-10-09); the remap actions (Manager::Remap); S22b, ruled 2026-10-09 ("Yes, (a)-(d)"): the users-tool client and the caps memo in Manager::Common, the memo in the fail-closed context; notices and start page (Manager::Notices, Manager::StartPage), after the ruled (b)-(d): the notices gate reads a token's own grant, the start page refuses an empty account, the dispatcher calls the notice readers directly; S23b and S24, ruled 2026-10-09 ("Yes, (a)-(d)"): `_emit_json` in Manager::Common, then the preview verbs in Manager::Preview after preview-grant and preview refuse an empty account (preview-clear unchanged); S25, ruled 2026-10-10 ("Yes, (a)-(d)"): describe-capabilities and actions-list in Manager::Describe after both refuse an empty account (site_capabilities unchanged); S26: channel-services, version and analyse_visitors in Manager::Services after analyse_visitors refuses an empty account (version, the transports' state, channel-services unchanged); S28: the site backup and export verbs in Manager::SiteBackup after site-backup-upload refuses an empty account (the established fail-closed pattern), the no-scope token rule in Manager::Common; S27, ruled 2026-10-10 ("Read Common's value"): domain-check and domains-list in Manager::Domains after domain-check refuses an empty account, read as Manager::Common's `$auth_user` by its full name (Domains' own log copy stays, on lint 217's closed list; Q16); S30: config-read, config-set and lang-status in Manager::Config after config-set refuses an empty account (the established fail-closed pattern; the site-fact readers unchanged); S29, ruled 2026-10-10 ("(a) load in main"): page-pdf in Manager::PagePdf after it refuses an empty account, the plugin loaded in package main (one line differs); next S31 - stopped on a design question with S32's (open questions, 2026-10-10) | after E5; largest, so last | L |
| Q15 | **[[SM943]] rulings - ruling 1 built (n309)**: a read is audited on neither door unless refused or failed, both trails held to one declaration (t/lint/23). Ruling 2 **built (n313)** on Q15b's host confinement ([[SM976]]): the structured nav read (`nav-read`, `read_nav`) needs no capability beyond the surface's base access, scope still applied; `nav-save`/`set_nav` and the raw `nav.conf` stay `manage_nav`; `manage_content` grants nothing nav-specific | ruled 2026-10-09 | S |
| Q16 | **[[SM944]] queued, not built (ruled 2026-10-10, "Queue it")**: retire the per-module `$auth_user`/`$action` log copies in Layouts, Domains and Themes - each entry point (API, MCP, WebDAV, CLI) sets the shared context once, the modules import it, the copies and their bridges go, and lint 217's exception list shrinks to the entry points | raised by S27's question; recorded only | not sized |
| Q16a | **built (n333)**: `tools/handoff.sh` run in a linked git worktree, with the base checked out in another, ends detached at the base instead of failing to check it out - it said NOT READY after every gate passed (n308, n332); the main checkout returns to the base branch as before. A stack branch landed or deleted during the run is named "(landed or deleted during the run)" instead of a READY line with an empty SHA and git's "fatal: Needed a single revision" (t/tools/106) | found handing off n308 and n332 | XS |
| Q16b | **[[SM978]] security and the stray JSON tail, ruled 2026-10-10 - built (n336)**: "Scope it + composed parts" - page-pdf is path-scoped as preview is, the page's own read ACL is asked, and every part of a composed document is asked the caller's scope as well as the content ACL; a part outside the scope refuses the document, naming it (fail closed, as the page's refusal is); lint 218 counts calls, not words (page-pdf had passed on the `main` in `main->can`), t/integration/122. "Keep audit, print nothing" - file-download, file-zip-download, backup-download, site-backup-download, data-export and page-pdf share one streamed path (`Manager::Upload::stream_attachment`/`stream_bytes`): nothing after the body, audited by the trail's rule; five of them exited before the audit block and were never recorded, and a refused backup-download answered nothing (t/integration/123) | found by the S29 agent, ruled 2026-10-10 | S |

Applied throughout: E8 (comments state the invariant) on every file touched.

Not in the queue, and why:
- C1 [[SM911]] - needs live scope state on edge; a request to the sites agent.
- D1-D4 - each waits on something outside this plan (named in Group D).
- E4 [[SM947]] - the toolchain's; brief filed.

Open questions raised while working the queue:

- ~~**Q14 (SM944 S31 and S32): stopped on design questions, 2026-10-10.**~~
  **RULED 2026-10-10 (SM944 § Ruled: S31's and S32's questions): ITEM 1
  "SECURITY first" - rotate-auth-secret refuses an empty account, first;
  S31 "(c) request IP into Common"; S32 "Yes, all four".**
  Nothing of either row is built. Test 205's question, asked of both rows'
  subs with the script loaded as the unit tests load it and the context as
  `reset_request_context` leaves it - nobody - then boss's cookie context,
  then a reset (tmp/sm944-s31-s32-refusal-probe.pl, .out):
  - S31: `action_audit` answers ok:1 with the whole trail (every actor and
    target, unscoped) and `action_recent_changes` with who last changed each
    target, for account ''. `_audit_trail_set` refuses already (a token
    holding nothing lacks `manage_config` and `audit_switch`).
    `_audit_trail_state`, `_audit_parse_line` and the two target derivers
    read no account; `_audit_cached_entries` reads the trail for its two
    callers and holds no identity.
  - S32: `action_whoami('')` answers ok:1 for account '' (engine version,
    layouts, services, site capabilities, the scope's deny list), and for a
    named account with nobody asking; `action_users('', sub=list)` and
    `action_principals` list every account (and group); `action_display_names`
    resolves the names asked; `action_rotate_auth_secret('')` ROTATES the
    site's auth secret - every session signed out - with nobody asking.
    `_operator` answers 0 and `_handler_who` a token holding nothing (both
    refuse already); `_manager_groups_from_settings` is a site fact.

  The established fail-closed pattern fits each listed handler. What blocks
  each row is in the move (tmp/sm944-s31-s32-deps.pl, .out: the script subs
  and file-scope variables each row's subs reach):
  1. **S31: the N13-04 switch calls `_request_ip`**, the script's request
     address - a memo in a bare block over the script's `$LAZYSITE_DIR`,
     called by `_refuse` and the audit block too, and on no row. Moved
     verbatim, `_audit_trail_set` would die on its first switch. Options:
     (a) the switch stays in the script beside `_request_ip` and `_refuse`
     (the other audit writers that ask it), with a comment, and S31 moves the
     views and the two target derivers; (b) the moved call names
     `main::_request_ip()` (one line differs; it works only where the script
     is loaded); (c) `_request_ip` and its memo move into Manager::Common as a
     request fact - in a long-lived process the memo would otherwise carry one
     request's address into the next, so `reset_request_context` must clear
     it (lint 217, an eleventh fact); (d) the dispatcher passes the address
     in. **Recommended (a)**: no behaviour change and no new mechanism; the
     switch writes the trail rather than viewing it, and (c) is its own row
     if wanted.
  2. **S32: `_operator` fills `$IS_OPERATOR`** (`//=`, its memo). In
     Manager/Users.pm, which must import the fact, lint 217 fails: a file
     that imports a fact never assigns it (tmp/sm944-s32-lint217-probe.sh,
     .out). **Recommended**: `_operator` moves into Manager::Common beside
     `_user_caps` as the memo's one filler (lint 217's filled-by list gains
     it, the S22b shape), exported; the script's CSRF gate and Users import
     it.
  3. **S32: `action_rotate_auth_secret` names its argument `my ($auth_user)`**,
     shadowing the fact Users.pm imports for `action_users`; lint 217 fails
     on the declaration (the same probe). **Recommended**: an adaptation
     commit before the move renames the lexical (`my ($user) = @_;` and its
     one use in `log_event`) - it deparses the same but for the name; the
     alternatives are reading every `$auth_user` in `action_users` by its
     full name or a lint exception for a sub's own lexical.
  4. **S32: whoami's account is its argument.** The S25 shape refuses an
     empty `$user` (`action_describe_capabilities`), and still answers for a
     named account outside a request. **Recommended**: whoami refuses unless
     `$user` is non-empty and is the request's own `$auth_user` - inside a
     request the dispatcher passes `$auth_user`, so the answer is the same;
     outside one it never answers as an account nobody signed in as.
     `action_users`, `action_principals` and `action_display_names` refuse
     an empty `$auth_user`; rotate refuses an empty account before it opens
     /dev/urandom; each its own commit, proven and sabotaged.

  Also, for whichever row runs first: `_display_names` (SM778, one line) is
  called by S31's `action_audit` and S32's three readers; recommended as a
  trivial pure move into Manager::Common, exported and imported back (the
  `_no_scope_refusal` shape, S28). Not on either row and left in the script:
  `_table_audits_rows` (the audit block's SM677 question) and
  `_users_tool_call` (the keys-list and key-revoke branches' runner, S33).

- ~~**Q14 (SM944 S29): stopped on a design question, 2026-10-10.**~~ **RULED 2026-10-10: "(a) load in main", with the findings "Scope it + composed parts" (1, [[SM978]]) and "Keep audit, print nothing" (2); 1 and 2 built as Q16b (n336); S29 built (n337).** S30 was
  built (n335, from n333); S29 was not started. Outside a request
  (tmp/sm944-s29-s30-refusal-probe.pl, .out) `action_page_pdf` loads the
  pandoc plugin and converts a page for account '' - the content ACL lets
  account '' read a public page - so the established fail-closed pattern
  applies: refuse an empty `$auth_user` before the plugin is loaded (the
  dispatcher has refused one before any action). The choice is in the move.
  The sub loads the plugin with `do $plugin` and finds its converter as
  `main->can('convert')`; `do FILE` compiles the file into the CALLER's package
  (tmp/sm944-s29-pkgprobe.pl: `do` from package Foo defines in Foo, not main),
  and the plugin declares none. Moved verbatim into `Manager/PagePdf.pm`, the
  plugin's fifteen subs would be defined in Manager::PagePdf, `main->can`
  would find nothing and every page-pdf would answer "The Branded PDF plugin
  has no converter" (the probe, lifting the sub into a package, shows exactly
  that). Options: (a) the moved sub loads the plugin in package main
  (`my $loaded = do { package main; do $plugin };`) - one line differs from the
  script, the plugin's subs stay where they are today; (b) it asks
  `__PACKAGE__->can('convert')` - the plugin's subs (`describe`, `run`,
  `plugin_init`, `convert`, ...) move into Manager::PagePdf, and its
  `defined &log_event` finds PagePdf's import; (c) `action_page_pdf` stays in
  the script and S29 moves nothing. **Recommended (a)**: the same answer
  inside a request, the plugin's namespace unchanged, and lint 218's view of
  the sub unchanged (below).

  Found with it, not changed - both need a decision:
  1. **Security: page-pdf is not confined to the caller's domain.** It is
     declared `mutates => 1` with no `scoped`, so `_confine_scope` never sees
     its path, and nothing in it asks the domain rule. A cookie manager
     confined to content/clientA (manage_content, the test 31 fixture) gets
     content/clientB's page as a PDF, where `read` of the same path answers
     "outside your assigned scope" (tmp/sm944-s29-scope-probe.pl, .out). Lint
     218 section 5 counts page-pdf as asking the domain rule only because the
     word `main` in `main->can('convert')` matches lazysite-dav.pl's
     `sub main`, which asks. Recommended: declare it `scoped => 1` (as
     `preview` is), so it is refused outside the caller's scopes on both
     channels and lint 218 holds it as path-confined rather than by a name;
     and ask whether a composed document's parts should be confined the same
     way (`may_read` asks only the content ACL).
  2. page-pdf's dispatch branch does not exit after streaming, as
     site-backup-download's does: `respond()` then prints a second set of
     headers and `{"ok":true,"streamed":1}` after the PDF's bytes (past its
     Content-Length). A client honouring Content-Length drops the tail; one
     reading to the end gets a PDF with JSON after it. Recommended: decide
     whether the branch ends as site-backup-download's does (`exit 0` once
     streamed - which also skips the audit that page-pdf, declared mutating,
     now writes) or keeps the audit and prints nothing after the body.

- ~~**Q14 (SM944 S27): stopped on a design question, 2026-10-10.**~~ **RULED 2026-10-10: "Read Common's value" (option (a)); built with S27 (n330). "Queue it": retiring the per-module copies is Q16.** S28 was
  built (n331, from n329); S27 was not started. Outside a request
  (tmp/sm944-s27-s28-refusal-probe.pl, .out) `action_domain_check` runs its
  outbound DNS/TLS probe of a configured host for account ''; the established
  fail-closed pattern fits it in the script (refuse an empty `$auth_user`
  before the probe; the dispatcher has refused one before any action, and its
  branch asks the domain rule). `action_domains_list` lists no row there (the
  domain rule's filter) and `_instance_id` is a site fact: both unchanged.
  The choice is in the move. The row's target, `Manager::Domains`, declares its
  own `our $auth_user` - a log-attribution copy the dispatcher sets per request
  (`$Lazysite::Manager::Domains::auth_user = $auth_user`), which MCP, WebDAV
  and the domains CLI never set, and which `reset_request_context` does not
  reset: set to 'boss' and reset, the probe finds Domains' copy still 'boss'
  and Common's ''. Moved verbatim, the refusal would read that copy, which is
  not fail-closed after a reset. Options: (a) the moved check names Common's
  fact, `$Lazysite::Manager::Common::auth_user`, the one line that differs
  from the script's text; Domains' copy and its bridge (lint 217's closed
  list) stay; (b) Domains drops its copy and imports Common's, and the
  dispatcher's copy line goes - a change to what Domains logs from MCP,
  WebDAV and the CLI, and to lint 217's counts; (c) the row's three subs go to a
  new `Manager/DomainCheck.pm` that imports Common's `$auth_user`, leaving
  Domains as it is. **Recommended (a)**: same answer inside a request,
  fail-closed outside one and after a reset (test 205), Domains' logging
  unchanged; retiring the per-module copies is its own decision.

- ~~**Q14 (SM944 S25 and S26): stopped on a design question, 2026-10-10.**~~ **RULED 2026-10-10: "Yes, (a)-(d)"; (a), (b) and (d) built with S25 (n328), (c) with S26 (n329).**
  Neither row's handlers can move verbatim to their new module and pass test
  205's proof that a handler outside a request reaches nothing. Their source
  compiled in a package importing the request context, the context as
  `reset_request_context` leaves it (tmp/sm944-s25-refusal-probe.pl,
  tmp/sm944-s26-refusal-probe.pl, .out):
  - S25: `action_describe_capabilities('')` answers ok:1 for account '' - the
    capability map, the site's documentation index (3 pages on the probe's
    site) and every action's effects; `action_actions_list('')` answers ok:1
    for account '' on the token channel with the six actions a grant of
    nothing may call. Both take the account from the dispatcher, which has
    refused an empty `$auth_user` before any action runs (the auth check's
    `unless ( length $auth_user )`).
  - S26: `action_analyse_visitors` runs the stats plugin and returns its
    export (the stand-in's top page, `/secret-campaign`) with nobody asking;
    the control API gates it on `analytics`.
  - Answer without an account, site facts and no write: `site_capabilities`
    (enabled plugins' `provides`, read by whoami), `action_version` (the
    install's version), `_service_state` and `action_channel_services` (the
    killswitches, the capability sentences, which plugin owns a capability).
  Not choices: `_action_effects` reads `%MUTATING`, `%DESTRUCTIVE` and
  `%CHANGES_ACCESS`, which the script derives from
  `Lazysite::ControlApi::Actions` for its own gates and keeps; the module
  derives the same three from the same functions (its compile needs them; the
  answer is the same). The script imports `_json_bool`, `site_capabilities`
  and `_service_state` back for whoami (S32's row), and the dispatcher sets
  each module's `$DOCROOT` (and Services' `$LAZYSITE_DIR`). Recommended, as
  S24's (b)-(d): (a) `action_describe_capabilities` and (b)
  `action_actions_list` refuse an empty account, and (c)
  `action_analyse_visitors` refuses an empty `$auth_user` before it runs the
  stats tool - each the same answer inside a request (the dispatcher has
  authenticated a caller first), a refusal outside, its own commit with
  sabotage; (d) `site_capabilities`, `action_version`, `_service_state` and
  `action_channel_services` unchanged - site facts any signed-in caller
  reads, no account, no write, no tool run - with test 205 pinning that they
  answer. Skipped until ruled; nothing of S25 or S26 is built.

- ~~**Q14 (SM944 S24): stopped on a design question, 2026-10-09.**~~ **RULED 2026-10-09: "Yes, (a)-(d)"; (a) built as S23b (n323), (b)-(d) with S24 (n324).** The preview
  subs (`_preview_secret`, `action_preview_grant`, `action_preview_clear`,
  `action_preview`) cannot move verbatim to `Manager/Preview.pm` and pass test
  205's proof that a handler outside a request reaches nothing
  (tmp/sm944-s24-refusal-probe.pl, .out):
  - grant and clear print their responses through the script's `_emit_json`,
    which is on no row; the OPTIONS refusal and the rate-limit 429 use it too.
  - Outside a request `action_preview_grant` minted a signed preview cookie
    for account '' and, on a site with no auth secret, created one.
  - `action_preview` shells the processor for any path it is given.
  Not choices: `$PREVIEW_COOKIE` and `$PREVIEW_TTL` move with the area, and
  the dispatcher sets Preview's `$DOCROOT` and `$LAZYSITE_DIR` as for every
  module. Recommended: (a) a row before S24 that moves `_emit_json` and its
  comment into Manager::Common, imported by the script (a pure move, as S22b
  was); (b) `action_preview_grant` and (c) `action_preview` refuse an empty
  `$auth_user` - the dispatcher has authenticated a manager before either
  runs, so the answer inside a request is the same; (d) `action_preview_clear`
  unchanged, since it only expires the caller's own cookies. The comment above
  `action_preview` describes `processor_path`, already in Common, and would
  move there. Skipped until ruled.

- ~~**Q15g (SM976): malformed UTF-8 on the raw-bytes doors, 2026-10-09.**~~ **RULED 2026-10-09: "Refuse + walker skips", "Refuse existing target", "Pin with a test"; built as Q15h (n321).** A
  confined grant's upload of a page with one malformed byte in its front
  matter binds a form the write rule did not read, and so reaches that form
  (tmp/q15g-malformed-hijack-probe.out). One such page anywhere makes the
  walker die. Recommended: (a) refuse a raw-bytes `.md` write that is not
  valid UTF-8; (b) the walker treats a page whose reading dies as binding
  nothing, logged. Also SM977: should `copy_file` refuse an existing target,
  as the manager's copy does? Recommended: yes, through `action_copy`.

- ~~**Q14 (SM944 S23): stopped on a design question, 2026-10-09.**~~ **RULED 2026-10-09: "Yes, (a)-(d)"; (a) built as S22b (n319), (b)-(d) with S23 (n320).** None of the
  six S23 handlers can be moved verbatim and still pass test 205's proof that
  a handler outside a request is refused (tmp/sm944-s23-refusal-probe.pl):
  - `_notices_gate`, `_start_page_subject` and `action_start_page_set` call
    the script's `_user_caps` (memo `%USER_CAPS`) and `users_api`, and those
    two need `_users_tool_run`, `_users_tool_path` and `_tool_path`. None of
    these subs is on any row.
  - `_notices_gate` passes every token client (`return undef if
    $token_auth`), because the dispatcher has already required
    `notifications`. The fail-closed context is a token client, so a verbatim
    copy lets the call through when no request has been set up.
  - `_start_page_subject(undef)` with the reset's empty `$auth_user` answers
    for account '' instead of refusing.
  - The script's `action_notices` and `action_notices_seen` are wrappers with
    the same names as Notices.pm's readers.
  Recommended: (a) a row before S23 that moves the users-tool client and the
  caps memo into Manager::Common, with `%USER_CAPS` added to the context
  (reset to empty, lint 217); (b) `_notices_gate` reads
  `$token_caps{notifications}` for a token, which gives the same answer inside
  a request and refuses outside one; (c) `_start_page_subject` refuses an
  empty subject; (d) the dispatcher calls Notices' readers directly and the
  two wrappers are dropped. Skipped until ruled.

- ~~**Q10 (SM906 T3): what should a token caller be told when the USERS file is
  unreadable?**~~ **RULED 2026-10-07: (b) cannot-tell, unnamed; built n273.** Today it is "Invalid credentials" (MCP: reissue the token) - the
  secret cannot be checked, so naming the store to a caller who is not yet
  authenticated would disclose a host fault to anyone. Options: (a) keep it,
  and rely on the operator's log line; (b) answer `cannot-tell` 503 without the
  store name. Recommended: (b) - it fails closed and stops an agent being told
  to reissue a token that is fine. Open.

- ~~**Q2 (SM939 SC2) - R1 was ruled on a wrong premise.**~~ **RULED 2026-10-07: option (a).** My B1 row asked "support
  recursive delete, or answer 405?" as if recursive delete were missing. It is not:
  `do_delete` removes a collection with `remove_tree`, SM535 cleans up its pages,
  and t/unit/dav/04 asserts a non-empty collection DELETE answers 204 with the
  contents gone. The reported 500 is a PARTIAL failure - a directory INSIDE the
  collection not writable (the installer-made `docs/features/` tree SC1 fixed) -
  which `_write_failure` reports as a bare "Cannot delete the entry." because it
  checks only the top-level parent. Options: (a) keep recursive delete and make a
  partial failure answer 507 naming the directory that blocked it and what was
  left; (b) the 405 as ruled, which removes a working, tested capability.
  Recommended: (a). Skipped until ruled.

# Group A - ruled and ready to build

| Ref | Item | Size | Needs |
| --- | --- | --- | --- |
| A1 | ~~[[SM906]] T3~~ **built (n267)** - the control API answers a distinct "cannot tell" state when the auth store is unreadable, with the repair in the message (ruled 2026-09-29) | M | nothing |
| A2 | ~~[[SM912]] P4~~ **built e765424f; recorded n253** - a fixture that writes an ACL with an empty auth store exempts itself from SM901; make it visible (t/integration/43's fixture has no accounts) | XS | nothing |
| A3 | ~~[[SM869]]~~ **built (n269); adversarial review pending** - raw and escaped query values separated: escape at stash insertion, `%RENDER_QUERY` raw, the sink escapes unconditionally. Hostile-value render test first. XSS-adjacent, so the filing asks for an adversarial review | M | nothing - the release manager said "take it next" |

# Group B - needs a ruling

| Ref | Item | Size | The question |
| --- | --- | --- | --- |
| B1 | [[SM939]] SC2 - DELETE of a non-empty WebDAV collection answers 500 | S | Support recursive delete, or answer 405 saying "delete the contents first"? |
| B2 | ~~[[SM913]]~~ **S2+S4 built (n254)** S2/S4/S5 - spam that passes quarantine | XS/S/XS | S2: ship a list of link-shortener hosts as a stronger signal? S4: show each form's quarantine on/off in the manager? S5: ship a default `spam_keywords` list, or say why not? |
| B3 | ~~[[SM857]]~~ **built (n260)** read half - `(mine)` views of a table | M | Go-ahead to build it, with the filing's positions: an anonymous viewer sees no rows (never all rows), and a `(mine)` page bypasses the shared cache |
| B4 | ~~[[SM858]]~~ **built (n262)** - approve an account from a button on the Submissions view | M | Build it? It needs the form to declare `account_email:` and allocates the username from the address |
| B5 | ~~[[SM863]] part 2~~ **declined (R5)** - offer a known alias host as a labelled suggestion when a claim link has no site_url | S | Is a suggestion the operator must confirm better than none? |
| B6 | ~~[[SM932]] (2)~~ **built (n255)** - `lazysite check` writes a known line and reports which log sinks received it | S | Schedule it? (Item (1), an engine-owned diagnostic log, stays deferred on OP-29) |

# Group C - reproduce or measure first

| Ref | Item | Needs |
| --- | --- | --- |
| C1 | [[SM911]] LD4 - MKCOL on an existing collection answers 405 under /assets/ and 403 under /lazysite/layouts/ | Reproduce with live scope state; size XS once found |
| C2 | ~~[[SM883]] - six operations uniformly 1.20-1.27x slower since ~0.14.0~~ **measured (n277): the host on 2026-09-14; the window's code is flat** | Check the machine, then bisect 2026-09-10..13 |

# Group D - waiting on something outside this plan

| Ref | Item | Waiting for |
| --- | --- | --- |
| D1 | [[SM923]] limit 1 - sections in a long form | A second long-form report (ruled 2026-09-30) |
| D2 | [[SM887]] A5, E2/E5/E7 - the claude.ai skill on a real site | The release manager running it in a real conversation |
| D3 | [[SM888]] C3 - fix the five sites; C1/C2 live sweep | The sites agent (C3 is estate work) |
| D4 | [[SM747]] - Odoo integration | Its ruling |
| D5 | ~~[[SM942]]~~ **closed 2026-10-07** - FO1-FO3 built; R11 passed on edge; status `shipped` | - |

# Group E - development cost (filed 2026-10-07)

From the cost analysis: 98 of 529 commits since 2026-09-01 were bookkeeping, a
gate is ~90 minutes and 0.15.2 needed three, and an ordinary new action touches
13 files. In build order - E1-E3 first because they pay back inside this
release, E5 before the new actions R3 and R4 add.

| Ref | Item | Size | Needs |
| --- | --- | --- | --- |
| E1 | ~~[[SM950]] (1)~~ **built (n244)** - the gate suite runs with -j4 (17 min -> ~6); the host has the memory now | XS | nothing |
| E2 | ~~[[SM948]]~~ **built (n244)** - handoff regenerates the generated docs instead of failing on them | S | nothing |
| E3 | ~~[[SM949]]~~ **built (n244)** - a one-minute pre-check (lints, related tests, changed-line tidy) before the full suite | S | nothing |
| E4 | [[SM947]] - landing keeps the branch's SHAs (fast-forward), or stamps refs itself | M | the toolchain - vcs-review is theirs; brief filed |
| E5 | ~~[[SM943]]~~ **built (n259, n274)** - one declaration per control-API action, the rest derived | L | before R3/R4 add actions |
| E6 | ~~[[SM950]] (2)(3)~~ **built (n272)** - gate run on landing; coverage reused when its inputs are unchanged | M | E1 |
| E7 | ~~[[SM946]]~~ **built (n245)** - prose caps; the changelog keeps one minor, older ones archived | S | nothing |
| E8 | [[SM945]] - comments state the invariant; history to git and the filing | ongoing | applied as files are touched |
| E9 | [[SM944]] - the processor and the manager API split into modules, one area per branch | L | E5 for the manager API half |

# Group F - from the 0.15.2 edge walk (filed 2026-10-07)

| Ref | Item | Size | Needs |
| --- | --- | --- | --- |
| F1 | ~~[[SM951]]~~ **built (n247)** - the manager bell is never wired: its script runs in `<head>` before the bell exists (since at least 0.10.0); blocks R1 | S | - |
| F2 | ~~[[SM952]]~~ **built (n248)** - a form's rate limit counts the address's posts to every form, and refused-as-invalid posts spend it | S | nothing - ruled (R8) |
| F3 | ~~[[SM953]]~~ **built (n249)** - a missing submission's message names the store file | XS | nothing |
| F4 | ~~[[SM954]]~~ **built (n250)** - the submissions table shows "quarantined" without the stored reason | XS | nothing |
| F5 | ~~[[SM955]]~~ **built (n256)** - the XMPP test says sent when the server bounces it; delivery failures are not audited | M | nothing - ruled (R9) |
| F6 | ~~[[SM956]]~~ **built (n251)** - a visit of more than five pages at under ten-second gaps is a bot (owner rule 2026-10-06) | S | nothing - ruled |
| F7 | ~~[[SM957]]~~ **built (n265)** - menu review: Submissions page and menu entry with an unread count, Handlers off the menu, daily vs setup groups | M | nothing - ruled (R11) |


| Ref | Question | Ruling |
| --- | --- | --- |
| R1 | B1: a non-empty collection DELETE | ~~405 with a "delete the contents first" body; no recursive delete~~ **AMENDED 2026-10-07: keep recursive delete; a partial failure answers 507 naming the directory that blocked it** (the first ruling was made on a plan row that wrongly said recursive delete was missing) |
| R2 | B2: SM913 S2/S4/S5 | **Ship S2** (link-shortener hosts as a stronger signal) **and S4** (show each form's quarantine state). **S5 not shipped** - no default keyword list |
| R3 | B3: SM857 read half | **Build it in 0.15.3**, with the filing's positions: an anonymous viewer sees no rows; `(mine)` pages bypass the shared cache |
| R4 | B4: SM858 approve from a submission | **Build it in 0.15.3** - `account_email:` on the form, username from the address |
| R5 | B5: SM863 part 2 | **No.** The message names the path and the cause; setting site_url is the fix |
| R6 | B6: SM932 sink probe | **Schedule for 0.15.3**; item (1) stays deferred on OP-29 |
| R7 | A3: SM869's release | **In 0.15.3 with the rest**; the adversarial review still runs on its own branch |
| R8 | F2: SM952's rate-limit scope | **Per form**, and **only accepted submissions count** - a post refused by validation spends nothing |
| R9 | F5: SM955's delivery reporting | **The test button reports a refused recipient** (it waits for the bounce); **every delivery failure goes to the audit log** so it can be exported |
| R10 | Net::DNS's SBOM licence | **Keep MIT, with a note** naming the extra advertising clause |
| R11 | F7: SM957 menu review | **M1-M7 accepted; Handlers off the menu** (reached from forms and Extensions); **the Submissions entry shows an unread count** |
| R12 | SM971: coverage at -j4 or serially | **Coverage stays parallel (-j4)** - ruled 2026-10-09 |
