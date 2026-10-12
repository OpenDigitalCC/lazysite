---
title: "Work plan - 0.15.5"
subtitle: "What is open after 0.15.4: four security reports from the field, the end of the SM944 split, engine bugs and requests from the dev inbox, and follow-ups noted while working WORK-PLAN-0153. Sorted by what each needs next."
brand: plain
standard-margins: true
---

# How to read this

Every row is an open item, by its filing or inbox report. **Needs** says what has
to happen before it can be built. Rulings taken on this plan are quoted in the
row. WORK-PLAN-0153 is complete apart from its last two rows, which continue
here as P2 and P3.

# Build queue - worked in this order (set 2026-10-11)

The release manager: "keep going with the queue, i will review as a batch
later". Each item is one branch, stacked, handed off READY; an item that needs a
ruling the plan does not hold is skipped, its question goes to the open
questions below, and the next item starts.

## Security first

| P | Item | Ruling | Size |
| --- | --- | --- | --- |
| P1a | `manage_users` alone lets a session write any file past the file permissions, while `group-reach` says it can call nothing (inbox 2026-10-11, graded A) | "New approve capability": file ACLs apply to a `manage_users` holder; a new `approve_accounts` capability is enough to approve an account request; `group-reach` reports what each capability can do | M |
| P1b | An inline `auth_groups: [a, b]` list is ignored and the page is served to every signed-in user (inbox 2026-10-11, graded B) | "Parse it + fail closed": the flow list parsed on every reader; anything still unreadable refuses everyone and is logged; `lazysite validate` reports it | S |
| P1c | A `move` into a draft or read-restricted folder writes the file to the public docroot (inbox 2026-10-11, graded B) | "Land where save would": move, copy, upload and their MCP/WebDAV twins land in the private store; `acl reapply` can repair a misplaced file | M |
| P1d | A `manage_data` holder reaches tables its permissions exclude; a published table serves hidden rows to anyone (inbox 2026-10-11) | "Table ACLs bind it + row filter": table permissions apply to `manage_data`; published tables gain an optional row condition | M |

## The end of SM944, carried from WORK-PLAN-0153

| P | Item | Ruling | Size |
| --- | --- | --- | --- |
| P2 | S34, the CSRF write gate into Manager/Csrf.pm (0153 Q14) | "Yes, as planned": tests over every mutating action first, then the fail-closed refusal, then the 40-line move; "Audit refusals": a CSRF refusal is recorded as `denied: csrf` | M |
| P3 | Q16: retire the per-module `$auth_user`/`$action` log copies in Layouts, Domains, Themes and Data; then revisit Manager::Data's four inline branches (0153 Q16) | "Queue it"; survey first, stop if any log line changes | not sized |

## Engine bugs from the dev inbox

| P | Item | Ruling | Needs | Size |
| --- | --- | --- | --- | --- |
| P4 | `users-detail` reads every account (43 s for 695), so approving an account request times out in the browser | - | built (n390), SM983: the approval asks `users-detail` for `fields: ["email"]` only, 0.27 s for 700 accounts from 26.7 s | S |
| P5 | `&&` in a page body is a template parse error (it appears to reach TT as `&amp;&amp;`) | - | built (n391), SM984: convert_md lifts each `[% %]` tag past the Markdown converter; a tag in code is shown, escaped | S |
| P6 | A fenced code block that shows `:::` component syntax is expanded | - | built (n392), SM985: fenced code is converted first and held out of the `:::` passes; indented code was never affected | S |
| P7 | A setup link refused over plain HTTP says "invalid or expired" | - | built (n393), SM986: the refusal redirects with `error=https` and the claim page says a password can only be set over HTTPS | XS |
| P8 | The development server cannot receive a form post (404 for `form-handler.pl`) | - | built (n394), SM987: `/cgi-bin/form-handler.pl` runs `plugins/form-handler.pl`, directly, as installed | XS |
| P9 | A `scan:` stops at 200 pages with no warning, in file order | revise, 2026-10-12: "Keep, add per-scan limit=": keep `scan_limit` as the site ceiling; add `limit=` and `offset=` on a scan directive, capped by it; `_total` as built. Docs. | built (n395), SM988: `scan_limit:` in lazysite.conf (default 200, stable prefix), `<var>_total` of the pages the reader may see, a warning when capped; revised, built (n401), SM995: `limit=` and `offset=` on the directive page the filtered, sorted list, `limit=` capped by `scan_limit` | S |
| P10 | `lazysite provision` prints uninitialised-value warnings (install.pl ~1223) with no registry | - | built (n396), label install-plan: not the registry - three runtime paths carry `why` and no `purpose`; the plan prints `why` | XS |
| P11 | `acl set --draft` over a folder already held: a rewrite leaves the private copy and `reapply` refuses | - | depends on P1c (security agent, not landed on 2026-10-11): skipped, to confirm once P1c lands | XS |

## Requests from the dev inbox (each needs a ruling before it is built)

| P | Item | Ruling | Needs |
| --- | --- | --- | --- |
| P12 | Registry objects carry only seven fields; give them the page's other front matter (as a scan object has) | 2026-10-12, with P13: "Full front matter + general lists": registry objects carry the same front-matter keys a scan object has (minus engine-private keys - define the private set and say it); any YAML block or flow list is parsed as a list (not only tags), in the scan and registry objects and page vars - check SM980's single access-key reader is not disturbed and the processor/lib marked copies stay equal. | ruling: which keys, and how lists are parsed |
| P13 | YAML list keys other than `tags` (`categories:`) arrive as raw text | 2026-10-12: with P12, "Full front matter + general lists" (see P12). | ruling: parse lists generally, or document which keys are lists |
| P14 | An alias host names itself as canonical; render canonical, sitemap and `llms.txt` from the canonical domain | 2026-10-12: "Render from the canonical": for a host registered as an alias (alias_of), canonical link, sitemap and llms.txt addresses use the canonical domain's address; the alias keeps serving under its own name. | ruling: render from the canonical, or document a web-server redirect |
| P15 | The visitor log records no host, so a multi-domain instance cannot answer per-domain questions | 2026-10-12: "Record host": each visitor-log event carries the served host; analyse_visitors filters/groups by host; a confined caller sees only its own domains' traffic (SM976 rule). Counting basis note if the report shape changes. | ruling: record the served host with each event |
| P16 | The CSP has no way to allow one external host | 2026-10-12: "Add allow-lists": csp_script_src, csp_connect_src, csp_img_src, csp_frame_src in lazysite.conf, each a list of https origins (validated: no 'unsafe-*', no bare *, only scheme+host[:port], a leading *. subdomain wildcard allowed), appended to the default; per domain on multi-domain instances; check reports bad entries. | ruling: `csp_script_src` / `csp_connect_src` (and img, frame) lists, per domain |
| P17 | `(mine)` cannot read the viewer's own rows from a table they may not otherwise read (corrected report, 20:00) | 2026-10-12: "Allow own rows": `(mine)` returns only rows whose created_by is the signed-in viewer even when the table's read rule excludes them; anonymous gets nothing; the data endpoint and listings still follow the rule. SECURITY-sensitive: prove no other row leaks (other viewers' rows, totals, counts). | ruling: whether `(mine)` may bypass the table's general read rule for own rows |
| P18 | A handler that mails recipients taken from data (followers of a post), to verified account emails only, with a per-recipient limit and an audit line per delivery | 2026-10-12, the release manager: "write up a brief ... generic, use other notification mechanisms, be triggered by form submit or scheduler ... brief it." Then ruled 2026-10-12 (recorded in SM1010 "Ruled"): phase 0 "Fix now" (F1, F2); recipients "Yes, engine = mechanism" - tables, owners, fixed, submitter, the engine guards technical safety only and compliance is the operator's; authoring "New 'manage_notifications' cap"; unsubscribe "Per rule, default on"; the rest as the brief recommended (Q2, Q3, Q4 overridden). | built: phase 0 SM1017 (n440); phase 1 SM1018 (n441), SM1019 (n442), SM1020 (n443, n444); what remains is SM1010 R1-R7 |
| P26 | A member home page: password, 2FA, the bell, sessions, unsubscribes, in the site theme and outside the manager (SM1010 R2; folds in R1, R4) | 2026-10-12, the release manager on SM1010's open items: "maybe we need a user home page, that uses the site theme and sits outside manager, offering basic functions, password, 2fa, bell etc." Then ruled 2026-10-12 (recorded in SM1034 "Ruled"): "Accept, build phase 1" with Q1-Q9 as recommended; "Fix now" - any password change or 2FA disable ends the account's other sessions, the current one stays (SM1040); "Min 12, configurable" - `password_min_length`, default 12, on every way a password is set (SM1041); 2FA "Self-enrol only" - managers reset or disable, never see a secret, and manager enrolment goes in the same branch as self-enrolment (SM1042). | brief filed SM1034 (n445); building in order: SM1040 (n446), SM1041 (n500), phase 1a `/account` and `me-*` (SM1043), 1b own notices, 1c self-enrolled 2FA (SM1042), SM1010 R5 |

## Follow-ups noted while working WORK-PLAN-0153

| P | Item | Ruling | Needs | Size |
| --- | --- | --- | --- | --- |
| P19 | The coverage floor (`dist/config/coverage-floor`) names only the CGIs; the processor's 19 parts and the manager modules that left them are held to no floor | 2026-10-12: coverage floors per moved file: the floor covers the processor's parts and the manager modules that left the CGIs (decide: per-file floors or a floor over each former CGI's parts - choose the one that keeps the gate meaningful and explain); run tools/coverage.sh --check only within the gate's lock rules; if measuring needs the gate, state the floors and leave a note for the coordinating session to verify at the next gate. | ruling: floors per moved file, or one floor over each former CGI's parts | S |
| P20 | `_render_form` (forms.pm), `main` (the processor) and `render_content` (render.pm) are each hundreds of lines; they need a split that is not a pure move | 2026-10-12: "_render_form now, hold main" - render_content after _render_form, main decided after seeing them; the comparison tools into tools/; one sub per field kind; the characterisation records committed; P19 floors first, not awaited, the floor file untouched | SM1012: tools (n450); _render_form characterised (n451) and split, S1-S6 (n452-n457); render_content characterised (n458) and split, S7-S11 (n459); main held; the answers and the build record are in SM1012 | L |
| P21 | Lint 137 (a row writer names its actor) reads only the top-level `*.pl` files, by design; the writers now live in modules | revise, 2026-10-12: "Keep original authors": a restored site package's rows keep the created_by/updated_by they were exported with (change n398's behaviour); the audit trail records who applied the package. Lint 137 must still pass (it requires actor =>). | built (n398), SM989: lint 137 holds every insert_row/update_row/import_rows call in lib/, tools/, plugins/ and the root to `actor =>`; it found package_apply restoring rows as nobody, fixed | XS |
| P22 | 31 filings still say "SHIPPED (PENDING)" after their release shipped | 2026-10-12: the release step stamps "SHIPPED (PENDING)" status-notes with the released version (tools/release-material.pl) and a one-off sweep fixes the 31 already-released filings (verify each against the released CHANGELOG sections). | the release step stamps the version into the status-note, or a sweep does | S |
| P23 | The nav parser stores a `javascript:` URL as written | 2026-10-12: refuse or neutralise unsafe URL schemes (javascript:, data:, vbscript:, ...) in nav.conf at write (set_nav/nav-save/WebDAV PUT of nav.conf) and at render; existing entries render as '#', logged; validate/check report them. | ruling: refuse or neutralise unsafe schemes in `nav.conf` | XS |
| P24 | The control API's `users` read sub-actions (including `verify-credential`) write no audit row when they fail; a crashing handler writes none on any surface | 2026-10-12: under SM943's audit rule (refusals and errors are audited): the control API's `users` read sub-actions (incl. verify-credential) write an audit row when they fail; a handler that crashes writes one failure row on every surface (API, MCP) naming the action, never the error's secret content. | under SM943's rule (refusals and errors are audited) | S |
| P25 | The scan's page read still dies on a page it cannot open (permissions), outside the encoding rule | - | built (n399), SM990: both walks open the page inside the Q15h guard; left out, logged by relative path with the reason | XS |

## From the 0.15.4 upgrade of sites.lazysite.io (release manager, 2026-10-12)

"adding group to domains, then press save - message: Nothing had changed. also
- groups should be prefixed with something say @ so they can be distinguished
from users, and this should be consistent anywhere a group is picked. lets have
cli command to add the domain group."

| P | Item | Ruling | Needs | Size |
| --- | --- | --- | --- | --- |
| U1 | The Domains page's Access pickers never save: Save says "Nothing had changed." | - | built (n430), SM1013: the dirty check read the picker by a class it was never drawn with (`mg-token-box`, drawn `mg-tokens`); a pill added or removed marks the field and Save posts it; the same check found the Connectors page saving `callers: []` whenever its caller groups were drawn as checkboxes, fixed in the same item | XS |
| U2 | Groups are named plainly on some pages and `@name` on others | 2026-10-12: "groups should be prefixed with something say @ so they can be distinguished from users, and this should be consistent anywhere a group is picked" | built (n431), SM1014: `@name` on every group picker and beside people (layout mgGroupLabel/mgGroupName; groupPrefix retired, lint 230); input with or without `@`; each store keeps its form (ACL `@g`; allowed_groups, members, callers `g`) | S |
| U3 | A command to add one group to a domain from the shell | 2026-10-12: "lets have cli command to add the domain group" | built (n432), SM1015: `lazysite-domains.pl group-add/group-remove --host H --group G` (and `user-add/user-remove --user U` for locked_users) through domain_set; idempotent; an unknown group or account refused by name | XS |
| U4 | A domain's access keys accept a group or account the site does not have | 2026-10-12: "lazysite-domains.pl should reject invalid groups" (every surface, through domain_set) | built (n433), SM1016: domain_set refuses each unknown NEW name in allowed_groups / locked_users, naming them, writing nothing; names already held are not asked about; the Domains page shows a refusal; confirmed 2026-10-12, "keep the design choice": only names being added are checked, so a group deleted after it was allowed never makes the list unwritable | XS |
| U5 | `lazysite check` run as a user that cannot read groups-settings.json says the manager is unconfigured (as root: "manager bootstrapped") | 2026-10-12: absent is unconfigured; unreadable is a named finding (state unknown, run as root or the site user); undecodable is a FAIL naming the file; sweep the other security-relevant reads | built (n435), SM1023: three-way reads of groups-settings.json, auth/users + auth/groups (manager account), lazysite.conf (`manager: enabled`) and acls.json; `--check-acl` skips on an unreadable or undecodable acls.json. Found: an undecodable groups-settings.json is read as unsecured by Auth::Settings (manager API, sign-in) and as secured by the render path - filed as SM1024 | S |

# Not in the queue, and why

- C1 SM911 - needs live scope state on edge; a request to the sites agent.
- D1-D4 - each waits on something outside this plan.
- E4 SM947 - the toolchain's; brief filed.
- SM747 (Odoo) - specified and sized; waits on a ruling.
- The catalogue layouts' `| url_safe` - the layouts repository, not this one.
- OP-46, OP-47 - host items on the operator list (edge's install user and web template).

# Open questions raised while working the queue

- **P9 (SM988), built, two choices to confirm.** (1) The cap is a site-wide
  `scan_limit:` rather than `limit=`/`offset=` on the directive. (2)
  `<var>_total` is counted before `filter=`, because a page past the cap is
  not read and cannot be filtered; with a filter it can exceed what the filter
  would list. Keep both, or add per-directive paging? Answered 2026-10-12 (P9 row): keep `scan_limit` as the ceiling and add `limit=`/`offset=`; `_total` as built.
- **P18 (SM1010), found while reading: a quarantined submission is probably
  acknowledged.** `_acknowledge_submitter` asks `$fields->{_quarantined}`
  (Handlers.pm:1881), but the form handler strips `_` keys before delivery and
  passes the flag as context (form-handler.pl:288, :295), so the SM877 message
  goes to an address a suspect submission chose. Read, not run (B). A fix
  branch, ahead of SM1010 (its F1 and Q9)? Answered 2026-10-12: "Fix now" -
  reproduced through form-handler.pl and fixed with F2, SM1017 (n440).
