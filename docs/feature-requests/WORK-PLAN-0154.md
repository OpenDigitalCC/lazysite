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

| P | Item | Needs | Size |
| --- | --- | --- | --- |
| P4 | `users-detail` reads every account (43 s for 695), so approving an account request times out in the browser | built (n390), SM983: the approval asks `users-detail` for `fields: ["email"]` only, 0.27 s for 700 accounts from 26.7 s | S |
| P5 | `&&` in a page body is a template parse error (it appears to reach TT as `&amp;&amp;`) | built (n391), SM984: convert_md lifts each `[% %]` tag past the Markdown converter; a tag in code is shown, escaped | S |
| P6 | A fenced code block that shows `:::` component syntax is expanded | built (n392), SM985: fenced code is converted first and held out of the `:::` passes; indented code was never affected | S |
| P7 | A setup link refused over plain HTTP says "invalid or expired" | built (n393), SM986: the refusal redirects with `error=https` and the claim page says a password can only be set over HTTPS | XS |
| P8 | The development server cannot receive a form post (404 for `form-handler.pl`) | built (n394), SM987: `/cgi-bin/form-handler.pl` runs `plugins/form-handler.pl`, directly, as installed | XS |
| P9 | A `scan:` stops at 200 pages with no warning, in file order | a documented, configurable cap or `limit=`/`offset=`, and a `<var>_total` | S |
| P10 | `lazysite provision` prints uninitialised-value warnings (install.pl ~1223) with no registry | guard the value | XS |
| P11 | `acl set --draft` over a folder already held: a rewrite leaves the private copy and `reapply` refuses | covered by P1c's `reapply` fix; confirm | XS |

## Requests from the dev inbox (each needs a ruling before it is built)

| P | Item | Needs |
| --- | --- | --- |
| P12 | Registry objects carry only seven fields; give them the page's other front matter (as a scan object has) | ruling: which keys, and how lists are parsed |
| P13 | YAML list keys other than `tags` (`categories:`) arrive as raw text | ruling: parse lists generally, or document which keys are lists |
| P14 | An alias host names itself as canonical; render canonical, sitemap and `llms.txt` from the canonical domain | ruling: render from the canonical, or document a web-server redirect |
| P15 | The visitor log records no host, so a multi-domain instance cannot answer per-domain questions | ruling: record the served host with each event |
| P16 | The CSP has no way to allow one external host | ruling: `csp_script_src` / `csp_connect_src` (and img, frame) lists, per domain |
| P17 | `(mine)` cannot read the viewer's own rows from a table they may not otherwise read (corrected report, 20:00) | ruling: whether `(mine)` may bypass the table's general read rule for own rows |
| P18 | A handler that mails recipients taken from data (followers of a post), to verified account emails only, with a per-recipient limit and an audit line per delivery | ruling; the report gives a full specification |

## Follow-ups noted while working WORK-PLAN-0153

| P | Item | Needs | Size |
| --- | --- | --- | --- |
| P19 | The coverage floor (`dist/config/coverage-floor`) names only the CGIs; the processor's 19 parts and the manager modules that left them are held to no floor | ruling: floors per moved file, or one floor over each former CGI's parts | S |
| P20 | `_render_form` (forms.pm), `main` (the processor) and `render_content` (render.pm) are each hundreds of lines; they need a split that is not a pure move | plan first | L |
| P21 | Lint 137 (a row writer names its actor) reads only the top-level `*.pl` files, by design; the writers now live in modules | widen it, with sabotage | XS |
| P22 | 31 filings still say "SHIPPED (PENDING)" after their release shipped | the release step stamps the version into the status-note, or a sweep does | S |
| P23 | The nav parser stores a `javascript:` URL as written | ruling: refuse or neutralise unsafe schemes in `nav.conf` | XS |
| P24 | The control API's `users` read sub-actions (including `verify-credential`) write no audit row when they fail; a crashing handler writes none on any surface | under SM943's rule (refusals and errors are audited) | S |
| P25 | The scan's page read still dies on a page it cannot open (permissions), outside the encoding rule | name it and skip, as Q15i did for encoding | XS |

# Not in the queue, and why

- C1 SM911 - needs live scope state on edge; a request to the sites agent.
- D1-D4 - each waits on something outside this plan.
- E4 SM947 - the toolchain's; brief filed.
- SM747 (Odoo) - specified and sized; waits on a ruling.
- The catalogue layouts' `| url_safe` - the layouts repository, not this one.
- OP-46, OP-47 - host items on the operator list (edge's install user and web template).

# Open questions raised while working the queue

(none yet)
