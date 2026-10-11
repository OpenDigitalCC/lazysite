---
title: "Test plan - 0.15.3 and 0.15.4 on edge, complete"
subtitle: "Every user- and operator-visible change in both releases, in the order that finds the most first: two upgrade checks, forty-three release-specific rows that only a deployed host can run, what was deliberately left unwalked, and the standing tiers. Supersedes the partial plan of 2026-10-10."
brand: plain
standard-margins: true
---

# What this plan is for

0.15.3 was published on 2026-10-09 and went to edge with no plan of its own.
0.15.4 is about to be cut from main 5598d70a. Between them they carry 95
CHANGELOG entries. About half are SM944's moves of code into modules, which
change no answer a request gets; the rest are security fixes, fixes from the
0.15.2 edge walk, and new behaviour.

- 0.15.3 gate: 1,074 files, 16,889 tests.
- 0.15.4 gate on 5598d70a: (filled in when the gate passes).

The suite cannot see four things these releases depend on.

**Real grants on real sites.** The tests build their own tokens, grants and
domains. Whether an existing partner token on a live multi-domain site still
does its job after the upgrade is a question only a deployed site answers.

**A FastCGI pool under real traffic.** SM973 is about what a pooled worker
remembers between requests; the tests drive the request loop in one process.

**What browsers, WebDAV clients and mail or chat servers actually do.** The
bell, the Submissions page, the Appearance page's domain choice, the bytes a
WebDAV client uploads and the bounce an XMPP server sends are exercised by
fixtures and stand-ins, not by the clients and servers people use.

**A host's clock, files and permissions.** The stats day (SM974), an
unreadable auth store (SM906) and a folder the server cannot write (SM939)
depend on the host, not on the code.

This plan supersedes the partial plan filed on 2026-10-10 ("domain confinement
and bad pages"). Its rows are kept where they are still right and corrected
where later work changed them; the numbering is new. Old to new: R1-R3 stay
R1-R3, R4 is R6, R5 is R7, R6 is R25, R7 is R27, R8 is R28 and R29, R9 is R31,
R10 is R40, R11 is R41, R12 is R35, R13 is R36 and R37, R14 is R38, R15 is R39,
R16 is R14.

**How to reach each surface.** The control API is
`/cgi-bin/lazysite-manager-api.pl?action=<name>`; a token client sends HTTP
Basic with the account name and its `lzs_` token, on a site with
`control_api_enabled: true`. A cookie manager can call the same actions from
the browser console of any manager page, where the manager's own `fetch` adds
the CSRF header to a POST:

```
fetch('/cgi-bin/lazysite-manager-api.pl?action=NAME', {method: 'POST',
  headers: {'Content-Type': 'application/json'}, body: JSON.stringify({...})})
  .then(r => r.json()).then(console.log)
```

MCP rows name the tool; WebDAV rows name the method.

**Marks used on the rows.** *Two domains*: a site that serves the primary and
at least one domain with its own content root. *Test site*: a throwaway site or
domain, never a live one. *Shell*: needs a shell on the host as the site user.

# Before anything else: the upgrade checks

The behaviour changes in both releases can take a working partner's access
away, and three of them need a configuration or authoring change on the site.
Check these on every edge site BEFORE walking the rows, and report what you
find even when nothing breaks.

## U1 - who loses what, and who gains what

For each token, MCP grant, WebDAV account and cookie manager on a site with
more than one domain, note its scope (which domains name its group in
`allowed_groups`). After the upgrade:

- One with **no scope** reaches the primary site, and any domain with no
  content root of its own, only. It is refused `domain-set`, `domain-add`,
  `domain-alias-add`, `domain-remove`, `remap-save`, `site-backup-apply` and MCP
  `domain_set`, `remap-list` shows it no rules (SM975), and from 0.15.4 a `host`
  on `theme-activate` or `layout-activate` is refused it. It no longer reads or
  writes another domain's navigation, and writes the primary's only when no
  domain with its own content root inherits it (SM976). It cannot write a theme
  or layout that a domain with its own content root serves (0.15.4, SM976 F1).
  To restore domain writes, name its group in that domain's `allowed_groups`
  (Domains page).
- One **scoped to some domains** reaches only those domains on every surface,
  and is refused the instance-wide actions: configuration, theme or layout
  activation without a `host`, the layouts library, extensions, the IP
  blocklist, the audit-trail switch, `git-init`, `rotate-auth-secret`, instance
  backups, the connector, handler and schedule registries and `briefs-migrate`
  (SM976 R1). From 0.15.4 it reaches a form only when every page binding it is
  inside its scope, a brief only of a page inside its scope, and no safety
  export written before 0.15.4, even of its own table (SM976 F2, F3).
- A **cookie manager bound to no domain** now reaches every data table (SM976
  R2/R4). An **unbound token or grant** now reaches safety exports written
  before 0.15.4 of any table (F3).
- The structured nav read (`nav-read`, MCP `read_nav`) no longer needs
  `manage_content` or `manage_nav` (SM943); writing the nav, and the raw
  `nav.conf` over WebDAV, still need `manage_nav`.

*Report:* each credential that was doing something it can no longer do, and
whether that was intended. It is a FAIL if the operator's own cookie session,
or a single-site site's credentials, lose anything.

## U2 - what the site itself may need changed

Check each site's configuration and pages for these, and report any site that
needs a change:

- **Custom auth or payment header names** (SM960, SM972). A site that sets
  `auth_header_user` (or another `auth_header_*` name) or
  `payment_header_verified` / `payment_header_payer` to a custom name must also
  set `auth_proxy_trusted: true`. Until it does, those headers are discarded:
  visitors read as signed out and paid content is not served. Default-named
  sites are unaffected.
- **`| html` on a query value** (SM869). `query.*` is escaped once by the
  engine, so `query.x | html` escapes twice (`&` arrives as `&amp;`). Search the
  site's pages and layouts (MCP `search_files` for `query.`) and remove the
  filter. The shipped login and claim pages already dropped theirs.
- **Usernames** (SM962). A script or form flow that relied on `add` shortening
  a name with other characters (`jo+hn` to `john`) now gets an error naming the
  character.
- **Statistics** (SM974, SM956). A site on a host not set to UTC that reads the
  web-server log now gets UTC days; the upgrade day may be split across two.
  Counting basis 5 moves fast page runs from `unattributed` to `bot`, so
  `unattributed` steps down from the upgrade on. Anything that reads the
  report needs to know.
- **`host` on theme or layout activation** (0.15.4, SM976 F4). A client that
  sent `host` to `theme-activate` or `layout-activate` used to change the whole
  instance; it now changes that domain only.

# The order

1. Record the version the check panel REPORTS, not the tarball's. That pages
   render at all is the check that the processor's parts (the
   `lazysite-processor/` folder beside the script, new in 0.15.3) were
   installed.
2. U1 and U2 above.
3. 0.15.3 security: R1 to R4 on a two-domain site first, R7 on a
   FastCGI-pooled site, then R5, R6 and R8 to R14.
4. 0.15.4 security: R27 to R35, on the same two-domain site.
5. The field-visible fixes from the 0.15.2 edge walk: R15 to R20.
6. The rest, in any order: R21 to R26, then R36 to R43.

# Release-specific checks - 0.15.3

## R1 - a token or grant with no scope reaches no other domain (SM975)

*Two domains.* With a token (or MCP grant) holding `manage_domains` whose group
no domain names: try `domain-set` and `remap-save` on a domain that is not the
primary, sending back its current values so a call that wrongly succeeds
changes nothing; `domain-alias-add` with a test alias name (remove it if it is
wrongly added); `remap-save` on a host the instance does not serve; and
`remap-list`. Try `domain-remove` and `site-backup-apply` only
against a test domain.

*You should see:* each write refused (403, kind `forbidden`), the message
saying the token names no `dav_scope`, so it reaches no domain, and that an
operator gives it one by naming the token account's group in that domain's
`allowed_groups` (Domains page). `remap-list` lists no rules. Nothing written.
The same writes from the operator's session succeed (on the test domain for
the remove and the apply). Then name the token's group on the test domain:
its writes there succeed.

## R2 - a scoped caller reaches only its own domains (SM976)

*Two domains.* With a credential scoped to domain A, on a site that also serves
domain B: `read_nav host=B`, `set_nav host=B` (send B's current nav), MCP
`domain_set` on B (including its `allowed_groups`, sent unchanged),
`domain-add` with a content root outside A (on a test host name), and
`list_domains`. As a cookie manager scoped to A: build, download and delete a
site package of B (from the browser console, `site-backup-create` with
`host` B), and `data-table-save` binding a test table to B.

*You should see:* every call on B refused (403), the message naming A's scope
and the domains it does reach; `list_domains` lists A only; the same calls on A
succeed. Repeat over WebDAV with a WebDAV account scoped to A: a GET and a PUT
(of the bytes the operator reads) of B's nav file are refused.

It is a FAIL if any call on B succeeds, or if a refusal names or lists B.

## R3 - a confined caller cannot change instance-wide settings (SM976 R1)

*Two domains.* With the credential scoped to A and holding `manage_config`,
`manage_themes` and `manage_layouts`: `config-set` of `site_name` (to its
current value); `theme-activate` with no `host`; MCP `activate_theme` with no
`host`; `bad-url-block` of `203.0.113.7`. As a cookie manager scoped to A: open
Backups (the instance backups list shows none), and on Sessions & keys press
**Sign everyone out** (`rotate-auth-secret`).

*You should see:* each refused (403), the message saying the action changes the
whole instance and that a domain-confined caller acts on its own domains only,
naming them. Nobody is signed out. Activation WITH `host=A` succeeds and changes
A only. The operator can still do each of these, but run the operator's
**Sign everyone out** only on a test site: it signs every session out,
including the tester's.

## R4 - data tables follow the domain rule (SM976 R2/R4)

*Two domains; the Data tables extension; tables whose descriptor names a
`domain:`.* With a credential scoped to A: `list_data_tables`, read the access
rule of B's table (`data-table-acl-get`), and `list_data_safety_exports`. As a
cookie manager bound to no domain: open Data tables.

*You should see:* the scoped caller sees A's tables and tables naming no domain,
and is refused B's access rule and B's safety exports. The unbound cookie
manager sees every table.

## R5 - the structured nav read needs no capability (SM943 ruling 2, stages 2-3)

With a token and an MCP grant that hold neither `manage_nav` nor
`manage_content`: `nav-read` and `read_nav` for the primary. Then `nav-save`
(or `set_nav`) with the same credential, and a WebDAV GET of `nav.conf` with a
WebDAV account that does not hold `manage_nav`.

*You should see:* both reads answer the navigation; the save and the WebDAV GET
are refused for want of `manage_nav`. In `describe_capabilities`, `read_nav`
is no longer listed under `manage_content`, and `write_data` no longer claims
the MCP tools `save_data_row` and `delete_data_row` (they need
`manage_data`).

## R6 - reads are not audited unless they fail (SM943 ruling 1)

Run a few successful reads (`read_page`, `read_notices`,
`describe_capabilities`) over MCP and over the control API, then one refused
read (a path outside the credential's scope), then a write.

*You should see:* in the Audit log, no rows for the successful reads on either
surface, one row for the refused read on each, one for the write.

Corrected from the partial plan: on 0.15.3 a download (`file-download`,
`site-backup-download` and the others) is never recorded, refused or not. The
0.15.4 rule for downloads is R34.

## R7 - a pooled worker sees a protection added after its first request (SM973)

*FastCGI-pooled site; test file.* Fetch an unprotected test file (a PDF works)
anonymously a few times so the workers have served it. Give it a read rule in
the manager and fetch it anonymously again, several times.

*You should see:* every fetch after the rule redirects to sign-in. Before this
build a worker that had already served it kept serving it until it restarted
(up to 500 requests). Remove the rule: it is served again.

## R8 - custom auth and payment header names are not trusted from anyone (SM960, SM972)

*Test site.* Set `auth_header_user: Remote-User` and leave
`auth_proxy_trusted` unset. Request a page gated `auth: required` with
`Remote-User: alice` in the request. Then set `payment_header_verified` to a
custom name and request a paid page sending that header.

*You should see:* the gated page sends you to sign in; the paid page is not
served; the site log has "untrusted header ignored" naming the header. Set
`auth_proxy_trusted: true` and the headers are honoured again. A site using
the default `X-Remote-*` names behind the built-in wrapper is unaffected.

## R9 - reflected and stored values stay text (SM869, SM964, SM965, SM966, SM968)

*Test site.* Make a test page with `query_params: [c]`, a form with a field
`prefill:c`, and a line that prints `[% query.c %]`. Then request it with:

- `?c=[% site_name %]` - SM869;
- `?form=<that form>&outcome=` followed by a URL-encoded line break,
  `::: include`, a line break, the path of another page, a line break and
  `:::` - SM965;
- with a `[% TAGS {{ }} %]` line added to the test page's body,
  `?form=<that form>&outcome={{ site_name }}` - SM968.

With a data table that public visitors write and a public page that lists it,
add rows whose text is `[x](javascript:alert(1))`, a `::: include` block naming
an unlisted page, and a backslash; read the list page and an `api: true` page
over the same table (SM964, SM966). On `/login`, use `?next=` with a path
carrying `&` and sign in (SM869).

*You should see:* every value shown as typed, never run, included or linked;
the prefilled field holds the literal text; the `api: true` response parses as
JSON; the TAGS line in the page body is ignored and logged; sign-in returns to
the `next` path with `&` intact, not `&amp;`. Remove the test page and rows.

## R10 - a form outcome is not cached for the next visitor (SM969)

*Test site.* Edit a page with a form so its cache is empty. Request it once with
`?form=<that form>&outcome=MARKER-TEST`, then request the plain page in another
browser.

*You should see:* the banner with MARKER-TEST only on the first request; the
plain page has no banner. Before this build the banner was baked into the cached
page for every later visitor.

## R11 - a whole link target keeps to a safe scheme with `| url_safe` (SM970)

*Test site.* On a test page with `query_params: [u]`, write
`<a href="[% query.u | url_safe %]">t</a>`. Request it with
`?u=javascript:alert(1)`, with the same scheme written with character
references and mixed case, then with `?u=https://example.org/` and `?u=/about`.

*You should see:* the first two give `href="#"`; the last two are unchanged and
not escaped twice. The built-in fallback layout's nav links behave the same.

## R12 - an unreadable auth store answers `cannot-tell` (SM906 T3, both entries and the follow-up)

*Test site; shell.* Note each file's mode first and put it back afterwards
(`lazysite check --docroot <docroot> --fix` repairs it).

1. Make `lazysite/auth/groups-settings.json` unreadable to the web server.
   Call `whoami` with a token on the control API and over MCP, and open the
   manager as a signed-in account that is NOT a manager.
2. Restore it, and make `lazysite/auth/users` unreadable. Call `whoami` with a
   good token.

*You should see:* in 1, the control API answers 503, kind `cannot-tell`, naming
`lazysite/auth/groups-settings.json` and the repair
`lazysite check --docroot <docroot> --fix`; MCP answers error -32003 with the
same fields; the non-manager account is NOT let into the manager (before, an
unreadable group store made every signed-in account an operator). In 2, 503
`cannot-tell` naming no store, saying not to reissue the credential; never
"Invalid credentials". The site log names the file in both.

## R13 - a token-gated action is gated for a manager account too (SM958)

Sign in as a cookie manager whose groups do not grant `manage_forms`. On a test
form, try to turn file uploads on (`form-uploads-save`) and change its notice
(`form-notify-save`). Without `manage_content`, try `regenerate-registries`.

*You should see:* each refused for want of the capability; the form's conf
unchanged. An operator, and a manager holding `manage_forms`, can still do both.

## R14 - blocking an address by hand works (bad-url-block)

Do NOT block your own address. Over the control API, `bad-url-block` with
`ip=203.0.113.7` (a documentation address), read the list with
`bad-url-blocks`, then `bad-url-unblock` with the same `ip` and read the list
again.

*You should see:* `added: true`, the address listed after the block, and gone
after the unblock (`removed: true`). Before this build the block action failed
every time and listed nothing.

In the manager, the list is under Extensions, on the bad-URL blocker's card,
**Blocked addresses**. The **Block this address** field is drawn only when the
list already holds an address; on a site with none it says "No addresses are
currently blocked." and offers no field, so use the control API there. Report
that as found.

## R15 - the manager bell works (SM951; SM957's read marks)

With at least three notices: on any manager page, click the bell.

*You should see:* the badge with the unread count and the panel opening; no
"mgToggleNotif is not defined" in the browser console. Follow one notice's link
and reload: that notice stays read (the read marks are POSTs now; before, none
was kept). **Mark all read** sends the badge to zero and it stays there on
reload.

## R16 - Submissions is the first menu entry, with an unread count (SM957)

Open the manager.

*You should see:* the menu in four groups, Site, Setup, Access and System;
Submissions first under Site, with the count of unread submission notices.
`/manager/submissions` lists every form, and a form's rows newest first with
the quarantine filter; each row opens `/manager/submission`. Extensions is one
entry. Handlers is not in the menu and is reached from a form and from
Extensions. An old `/manager/plugin-config?submissions=...` link lands on the
Submissions page. Locked entries keep their padlock and reason.

## R17 - a missing submission is named by its form, not its file (SM953)

Follow a submission notice, delete that submission, follow the notice again.

*You should see:* "no submission <id> on the form '<name>' - it may have been
deleted since the notice was sent". No file path anywhere in the message.

## R18 - the quarantine says why, and catches a link shortener (SM954, SM913)

*A form with quarantine on.* Submit once with `https://bit.ly/abc` in a field,
and once with the words "bit.ly is a shortener" and no link.

*You should see:* the first held, its reason shown as text beside the
quarantined tag in the Submissions table (readable on a phone, not only on
hover), naming the link shortener; the second not held. On the Handlers page
each form says "quarantine on" or "quarantine off".

## R19 - the XMPP test reports a recipient the server refuses (SM955)

*XMPP configured.* In the XMPP extension's configuration, run the delivery test
to a JID the server has no such user for.

*You should see:* the test fails at a `delivery` step with the server's
condition (for example `item-not-found`), where before it said "sent". The
failure is in the Audit log as `notify`, target `xmpp -> <jid>`, outcome
`failed`, with the cause. A good recipient passes.

A real notice does not wait for a bounce, so a refused recipient is not seen
there. To see a real notice's failure audited, on a test site only, break the
XMPP account's sign-in (a wrong password) and submit a test form: the Audit
log has the same `notify ... failed` row with the cause. Put the setting back.

## R20 - a form's rate limit is its own, and only a stored submission spends it (SM952)

*Test forms.* On two forms, one with a low `rate_limit:` in its conf: post to
the limited form up to its limit with a required field empty (each refused),
then correctly; then post to the other form.

*You should see:* the invalid posts spend nothing, so the correct one is
stored; posts to the limited form do not count against the other form. Once
the limit is reached by stored submissions, the next is refused.

## R21 - approving an account from a submission (SM858, SM962, SM963)

*Test site; test addresses only.* Give a test form `account_email: email` in
its conf, submit it with a test address, then sign in as an operator holding
`manage_users` and `read_submissions`.

*You should see:* an **Approve** button on that row in Submissions. Approving
makes an account named by the address's local part, lowercased; the row records
the account. Approving again, or a row whose local part holds `+`, a name taken
in any case, an address already on another account, or a quarantined row, is
refused by name and creates nothing. The `+` case reads "the address's local
part '<local>' cannot be a username: '+' is not allowed in one (letters,
digits, '.', '_' and '-' only) - nothing was created". On the Users page,
adding an account named `jo+hn` is refused the same way ("'jo+hn' cannot be a
username: ...") rather than creating `john`. If a group flagged for registrations cannot take the
account, the result and the success dialog list it as not placed, and the
Audit log row says `not-placed=`. Remove the test accounts afterwards.

## R22 - a page shows each signed-in viewer their own rows (SM857)

*Test site; a data table with `timestamps: true`.* Bind
`db:<table>(mine)` in a test page's `tt_page_var`, with rows created by two
accounts. View it as each account, then signed out. Then bind `(mine)` on a
table without `timestamps: true`.

*You should see:* each account sees only its own rows, never the other's, even
on a page with `ttl:`; signed out, no rows and no error. The table without
timestamps renders nothing, and the render log and `validate_page` say
"(mine) binding refused - the table has no created_by".

## R23 - a WebDAV folder delete that cannot finish says what stopped it (SM939 SC2)

*Test site; shell.* Make a test folder with pages and a subfolder, give the
folder a read rule, and make the subfolder unwritable to the server. DELETE the
folder over WebDAV.

*You should see:* 507, naming the subfolder and how many files were left, and
saying it is a server configuration fault. The pages that went are gone from
the sitemap, and the partial removal is committed to the content history; the
files left keep their read rule. Fix the
subfolder's permissions and send the DELETE again: it finishes.

## R24 - a fast run of pages is a bot (SM956)

*Test site; an ordinary browser User-Agent, not the agent one.* Open six
different pages, each within ten seconds of the one before. On another
browser, open six pages with gaps of ten seconds or more.

*You should see:* in the visitor report (`analyse_visitors`), the fast source
counted as `bot`, including its first five views, and the day's `bot_paced`
counting what moved; the slow source still `unattributed`. The report's
counting basis is 5.

## R25 - a stats day is a UTC day (SM974)

*A host whose clock is east of UTC; check `date` on the host first. On a UTC
host this row cannot fail: report it as not applicable.* Make a few visits
between local midnight and 01:00 (BST), then read the next day's Visitor
statistics.

*You should see:* those visits counted in the UTC day they happened in. Before
this build the last local hour of each day never reached the day's file. A site
that reads the web-server log now buckets by UTC day too; the day of the
upgrade may be split across two.

## R26 - `lazysite check --sinks` says whether syslog received a line (SM932)

*Shell; syslog forwarding configured.* Run `lazysite check --docroot <docroot>
--sinks`.

*You should see:* one result for the syslog sink: received (ok), or a FAIL
naming the facility, or a warning saying why it cannot tell or that forwarding
is off. Without `--sinks` nothing is written to the host log.

# Release-specific checks - 0.15.4

## R27 - a theme another domain serves cannot be written by a confined caller (SM976 F1)

*Two domains.* With a credential scoped to A: write a file into the theme that
domain B (or the primary) is serving, over MCP `write_file`, over WebDAV, and
through the manager's file editor (as a cookie manager scoped to A).

*You should see:* each refused (403, kind `served-artifact-refused`), saying
to copy the theme (`copy_theme` or `theme-copy`), edit the copy and activate it
with `host`. Writing into a theme only A serves, or an unused one, works.
Then, as the operator, upload a file over one in the instance's active theme
through the manager's upload, using that file's own current bytes: refused for
everyone, operator included (the multipart upload never checked this before).

## R28 - forms and briefs stay inside the caller's scope (SM976 F2)

*Two domains.* With a credential scoped to A: `form_list`, then read the
submissions and change the upload settings of a form bound only on B's pages;
read a brief for a page on B; `list_briefs`.

*You should see:* the lists show A's forms and briefs only; the form calls
refused (403) with "You cannot reach the form '<name>'", the same answer a form
that does not exist gets; the brief refused. An unbound token or grant still
reaches every form and brief.

## R29 - a confined caller binds no form it does not reach (SM976 Q15e)

*Two domains.* Pick a form no page binds but which has a conf or submissions
(it counts as the primary's). With a credential scoped to A, save a scratch
page in A's content with `form: <that name>` in the front matter: by MCP
`write_file`, by WebDAV PUT, and through the file editor.

*You should see:* each refused before anything is written (403, kind
`form-bind-refused`), the message saying the page would bind a form you do not
reach and to bind a form of your own (`create_form` with a new name); the
form's submissions still unreachable. Editing a page that already binds one of
A's forms still saves, and so does removing a binding. A brand-new form name
binds as before. Delete the scratch page.

## R30 - a page binds the form the processor renders (SM976 Q15f)

*Two domains; test pages placed by the operator.* Bind one test form on a page
in A (`form: shared-test`), and on a page in B with the value on the next line:

```
---
title: B test
form:
shared-test
---
```

With a credential scoped to A: `form_list`, `read_form_submissions` for
`shared-test`.

*You should see:* B's page renders the form; `shared-test` is not in A's list
and its submissions are refused, because a page outside A's scope binds it.
Before this build the B binding was not counted and A reached the form.
`validate_page` and `audit_site` name the same form for B's page. Remove the
test pages.

## R31 - theme and layout activation address one domain (SM976 F4)

*Two domains.* Sign in as a manager scoped to one domain, without
`manage_domains`; open Appearance and activate a theme. Then a manager scoped
to two domains. Then the operator. Over the control API, `theme-activate` with
`host=A` from a token scoped to A, and from a token with no scope.

*You should see:* for the one-domain manager, the note "You manage A: Activate
applies to that domain, not to the whole site.", activation on A only, and no
**Deactivate** button. The two-domain manager is asked which domain. The
operator's page behaves exactly as before. The scoped token's call changes A
only; the unscoped token's is refused (SM975).

## R32 - a safety export belongs to its table's domain (SM976 F3)

*Two domains; the Data tables extension; a test table naming domain A.* Drop or
rebuild the test table (which writes a safety export). With a credential scoped
to A, `list_data_safety_exports`; with one scoped to B, the same. Look also for
an export written before the upgrade.

*You should see:* the new export listed for A, not for B. An export written
before 0.15.4 is the primary's: a scoped caller no longer sees it, even of its
own table, and an unbound token or grant does. Restoring still needs the live
table's reach.

## R33 - a PDF is made only of pages the caller may read, and ends where it says (SM978, Q16b)

*The Branded PDF creation extension enabled and `md-to-pdf` installed; if not,
`page-pdf` says so and this row is not applicable.* Over the control API (POST,
`manage_content`), `page-pdf` with `path=` set to:

1. a page on domain B, from a token scoped to A;
2. a page whose read rule names another account, from a token not on the rule;
3. a page in A whose front matter lists `parts:` including a page on B, from
   the token scoped to A;
4. a page the token may read.

*You should see:* 1 and 2 refused before any PDF is made; 3 refused with "This
document includes '<part>', which is outside your assigned scope" and no PDF;
4 a PDF whose size equals the Content-Length header and which ends with the
PDF's own end marker (`%%EOF`), with nothing after it. Before this build a
`{"ok":true,"streamed":1}` followed the PDF.

## R34 - downloads are on the audit trail (Q16b)

Download a file from the Files page, a backup from Backups, and a data table as
CSV from Data tables (all GET). Then ask for a download that is refused: a
`backup-download` with a name that does not exist, and a `file-download` of a
path outside a scoped token's scope. Then POST a `file-download`.

*You should see:* the successful GET downloads write no row; each refused one
writes a `fail` row, and answers with its refusal as JSON (a refused
`backup-download` used to answer nothing at all); the POSTed one writes a row.
Before this build no download was ever recorded.

## R35 - a page that is not UTF-8 is refused at the door (SM976 Q15h)

Upload a `.md` page saved as Latin-1 with an accented letter (`José` with the
byte `0xE9`): over WebDAV PUT, over MCP `upload_file`, and through the
manager's upload. On a test site, also in a site package applied with
`site-backup-apply` or MCP `site_apply`.

*You should see:* each refused (415, kind `page-encoding-refused`), naming the
offset of the first invalid byte and saying to save the file as UTF-8. The same
page saved as UTF-8 uploads. It is a FAIL if any door stores the Latin-1 file.

## R36 - one bad page on disk no longer breaks the site (SM976 Q15h, Q15i)

*Test site; shell.* Place a Latin-1 page directly on disk (the doors now refuse
it) under a folder that a `scan:` page lists. Give a second test page UTF-8
front matter and a Latin-1 body, in the same folder.

*You should see:* the listing page, the home page and the sitemap still render;
before this build every page answered 500. The bad pages themselves still fail
to render, as before. MCP `list_pages`, `audit_site`, `form_list` and
`search_files` answer for the rest of the site and leave the bad pages out;
the engine log names each skipped page. `lazysite validate` given the folder's
pages reports the bad page as one it could not read, with the first invalid
byte, and checks every other file. Keep the pages for R37 and R38, then remove them.

## R37 - MCP answers a page that is not UTF-8 (SM976 Q15j)

*R36's pages.* Call `read_page`, `read_file`, `preview_page`,
`preview_public_page` and `validate_page` on the bad page, and `create_form`
on it.

*You should see:* each answers kind `page-encoding-refused`, with the first
invalid byte's offset and how to fix it. Before this build `read_page`,
`read_file` and `preview_page` answered with no JSON-RPC body, and
`validate_page` and `create_form` a bare "Tool error". `create_form` leaves the
page as it is.

## R38 - a version that is not UTF-8 is not restored, and a bad nav is named (SM976 Q15k)

*Test site; shell.* Commit R36's bad page into the content history (git, with
the site's `lazysite/git` as GIT_DIR and the docroot as work tree, as the site
user). `view_version` and `restore_version` (or the control API's
`git-restore`) to that version. Then save a copy of the primary's `nav.conf`,
write it back as Latin-1 with an accented label, and call `read_nav` and
`nav-read`.

*You should see:* `view_version` and the restore answer the encoding error
naming the version ("Version <sha7> of the page ..."); the page is left as it
is and no new commit is made. Restoring a UTF-8 version works byte for byte.
`read_nav` and `nav-read` answer `page-encoding-refused` naming the nav file,
where before MCP said "Tool error" and the control API sent no body. Put the
saved `nav.conf` back.

## R39 - the page walk says when it stopped (SM976 Q15j)

*More than 1,000 pages; on a smaller site, only the second half applies.*
`list_pages`, `audit_site`, and `rename_page` with `update_links: true` on a
test page.

*You should see:* `truncated: true` and `page_cap` in each answer, and
`count`/`pages` covering only the pages walked. On a smaller site, `truncated`
is false and no `page_cap` is given.

## R40 - create_form adds to the page instead of replacing it (SM977)

Over MCP, `create_form` on an existing test page using the extensionless path
the tool documents (`/about-test` for `about-test.md`). Then on a test page
with text and no front matter.

*You should see:* each page's existing text intact, with the form block
appended and `form:` added to its front matter (a front matter block added to
the page that had none). Before this build the page was overwritten with a
blank scaffold. On a path where no page exists, the page is created as before.

## R41 - copy_file refuses an existing destination (SM977)

`copy_file` onto a test page that already exists.

*You should see:* refused, kind `exists`, saying the target already exists and
to choose another or replace it with `write_file`. The destination is unchanged.

## R42 - a scoped grant can replace text inside its scope (SM976 path args)

With an MCP grant scoped to A: `replace_text` on a test page in A, with `old`
and `new` ordinary words. Then with `path` outside A.

*You should see:* the first succeeds; before this build ordinary text was
refused as "outside your assigned scope". The second is refused as before.

## R43 - a start-page name that sanitises to nothing is refused (SM944 S23)

As an operator holding `manage_users`, from the browser console: `start-page`
with `username=!!!`.

*You should see:* refused, "No account is named or signed in, so there is no
start page to read or set." Before this build it answered the start page of
account ''.

# Not walked, and why

**SM944's fail-closed refusals.** The 0.15.4 entries that make page-pdf,
config-set, domain-check, site-backup-upload, analyse_visitors,
describe-capabilities, actions-list, preview-grant, preview, audit,
recent-changes, whoami, users, principals, display-names and
`rotate-auth-secret` refuse when no account is asking act only outside a
request (a module loaded by a daemon or a test). Inside a request the
dispatcher has already refused an empty account, so they are not observable on
a deployed host; t/unit/manager/213-223 and test 205 cover them.

**SM944's moves, both releases** (S1-S22, S22b, S23b, S24-S33, and the
remap module): code moved unchanged into processor parts and manager modules;
no answer changes. The one move that changes an answer (S23, start page) is
R43; the processor's parts being installed is step 1 of the order.

**SM943 stage 1** (one declaration per action): no behaviour change.

**Release and gate tooling**: SM950, SM971, WORK-PLAN-0153 Q14a, Q14b, Q14d,
Q16a. They change how a release is gated and built, not what a site does.

**SM961** (a submission during a delete, confirm or approve): the window is a
rename lasting milliseconds and cannot be hit reliably by hand;
t/unit/forms/36 forces both directions by holding the lock.

**SM959** (a helper that exits before reading): needs a helper that dies on
start, which a healthy host does not have; t/unit/lib/199.

**SM967** (a value spelling an engine placeholder): the placeholders now carry a
per-call key, so there is no fixed word a tester can send; R9's probes run
through the same passes; t/unit/processor/91, t/unit/data/65.

**SM912 P4** (`principals_unchecked`): appears only when the auth store knows
no accounts or groups, which no deployed edge site has; t/tools/91.

# Standing tiers

Tier A before any promotion to beta or stable, as for every edge build. U1 and
U2 are part of this plan's promotion decision: report them even when every row
passes.
