# Upgrade notes

## How to upgrade — the one way, for every release below

This does not change per release, so it is stated once, here. Install the newer
lazysite on the host, then move each site to it:

```bash
lazysite upgrade --docroot /path/to/public_html          # one site
sudo lazysite upgrade --all                              # every registered site
```

`--dry-run` on the single-site form reports the plan and writes nothing.
From an unpacked tarball, before any package is installed, the same verb works
out of the tree: `perl tools/lazysite-cli.pl upgrade --docroot ...`. The
cgi-bin comes from the site's registry entry; a site with none (provisioned
before the registry existed, or on a host where `/etc/lazysite/sites.d` was
not writable) needs `--cgibin` too, and the verb says so. On a HestiaCP host
`--installdir /home/<user>/web/<domain>` stands for both paths.

**You say which operation you mean.** Nothing infers it from the state of the
disk, and each verb refuses rather than quietly doing one of the others:

| Verb | For | Refuses |
| --- | --- | --- |
| `provision` | a site that does not exist yet | a docroot that already has one |
| `upgrade` | moving an installed site to this version | nothing installed, or already at this version |
| `reinstall` | re-laying THIS version's files over a site that has them, leaving content, accounts and config alone | a version mismatch — that is an upgrade |

Not `reinstall` but `repair` when the files are right and the ownership, modes
or missing directories are not: `repair` touches no files.

Backups are written before every upgrade and reinstall:

```bash
lazysite backups --docroot /path/to/public_html            # list
lazysite backups --docroot /path/to/public_html --restore  # most recent back
```

`install.sh` installs nothing. It is kept as a signpost to the verbs above,
because the documentation named it for years and deleting it would strand
anyone still typing it.

**After an upgrade, restart anything holding engine code.** A plain CGI site
reads the engine fresh per request and needs nothing. A site on the persistent
runtime or the FastCGI pool has the previous engine in memory; the single-site
verbs name the units, and `upgrade --all` (root) restarts them itself.

**A security release reaches every site, stable ones included.** A release whose
manifest declares `"security_critical": true` (cut on stable with `tools/release.sh
--final --security-critical`; SM1314) is pushed past each site's `update_channel`:

```bash
# a HestiaCP host - its sites are not in the registry; as root:
bash /tmp/lazysite-X.Y.Z/installers/hestia/lazysite-hestia-update-all.sh --force-security
# a host whose sites are registered (/etc/lazysite/sites.d):
sudo lazysite upgrade --all --force-security
```

Both refuse the flag, before any site is touched, for a release that does not
declare itself security-critical. The Hestia updater names each site it forced
in the table, the findings and the summary, and each site's audit log records
`upgrade-forced`; a site excluded from the update (an install marker without the
lazysite-app template) stays excluded. On a Hestia host with no registry,
`lazysite upgrade --all` says to use the updater rather than reporting nothing
to do (SM1307).

Sections below are per-release notes, newest first. Where an older section says
`install.sh`, read it as a record of what that release did.

## Unreleased (0.16.8)

**Odoo's actions and capabilities are the extension's own declaration (SM1369, X2).**
The ten `odoo-*` control-API actions and `odoo_*` MCP tools, their parameters, their
gates, the tools' descriptions and schemas, and the capabilities `settle_odoo_writes`
and the new `manage_odoo` are declared by `extensions/odoo.pl` and read by the engine
from the extension index (`lazysite/extensions.index.json`), which the upgrade rebuilds
on every site, a new site's install builds, and the manager rebuilds when an extension is enabled, disabled or saved.
The wire names, the parameters and the listing an agent sees are unchanged. Nothing a
site configures changes.

**`manage_odoo` (ruling 71).** The Odoo connection user's key, the connection's state
and the call record (`odoo-status`, `odoo-calls`, `odoo-secret-set`, `odoo-secret-clear`
and their tools) were `manage_connectors`' and are now the extension's own capability,
`manage_odoo`, which also stands in for manage_connectors as the capability that may run
any Odoo binding. The upgrade tops up every group holding `manage_connectors` with it
and prints one line naming them (`groups:    topped up: <group> (manage_odoo), ...`;
nothing when none), so nothing changes for a group; a group whose operator has set it
off is left as decided. The same top-up still runs the next time the site's accounts
are touched, for a group given manage_connectors later. The Groups and Users pages show
it as "Odoo connection" under Site.

**If the index did not build.** The upgrade prints `declarations indexed: odoo` for a
site with Odoo installed. Should the build fail (a full disk, an unwritable
`lazysite/`), the previous index stands, the upgrade warns, and `lazysite check` says
so (`the extension index was not rebuilt by the last build`) until an extension is
enabled or saved in the manager or the upgrade is run again. On a site whose index was
built by hand before Odoo was enabled, the check names it (`enabled extensions whose
declarations are indexed and whose hooks are not`) and the actions answer "cannot run
now" until the index is rebuilt the same way.

**The Odoo browser helper and the sign-in component are the extension's (SM1369,
X5's asset part).** `/assets/lazysite-odoo.js` is no longer a file in the docroot: the
upgrade removes `{DOCROOT}/assets/lazysite-odoo.js` (it left the manifest; an edited
copy is kept with its orphan warning, and then still served by the front end as a
static file, so delete it to get the engine's) and lays the file out at
`{DOCROOT}/../extensions/odoo/assets/lazysite-odoo.js`, where the engine serves it
from at the same path, `/assets/lazysite-odoo.js` (and at `/assets/odoo-lazysite-odoo.js`),
on every domain, while the Odoo extension is on. The component `::: odoo-signin` moves
from `{LAZYSITE}/templates/components/` to `{DOCROOT}/../extensions/odoo/templates/components/`
and renders as before. The upgrade rebuilds the hook index, which is how the engine
finds both; a site that enables Odoo by editing `lazysite.conf` by hand must run
`lazysite upgrade` or `reinstall`, or save the extension's settings once, for the index
to be built. Nothing a layout references changes: `[% odoo_signin_banner %]`,
`[% odoo_display_name %]`, `data-ls-odoo-*` and the helper's path stay.

What does change: **with the Odoo extension off, the helper is not served and not added
to a page** (before, the docroot carried a copy whatever the conf said). A site that
used the helper with the extension disabled had nothing for it to talk to.

The front end needs nothing: a request for a missing `/assets/...` path already reaches
the engine on the shipped nginx and Apache configurations (`try_files` and
`FallbackResource`).

**The offline kit (SM1396).** A new extension, `app-offline`, off until enabled on the
Extensions page; it needs the Odoo extension on, and the Odoo sign-in as the site
sign-in (`odoo_site_signin: on`) to keep anything. Enabling it adds nothing to a page
until a layout renders `[% app_offline_kit %]`. On a site with the Odoo site sign-in,
the page endpoint's `?csrf=1` answers one more field, `owner` (a label of the
signed-in login, from the site session); a person already signed in has it at once.
On a default Odoo site `?csrf=1` names no owner and the kit keeps no reads and queues
no changes. The identity cookie is unchanged.

**A favicon for a site with none (SM1397)** and **`page_url_raw` (SM1398)** need
nothing from an operator.

**`owner_contact` is ignored from 0.16.8 (SM1412, ruling 159).** The `owner_contact:`
line in `lazysite/notify.conf` (0.16.6, SM1362) no longer mails a form's notice to that
address; nothing reads it. By default no form mails anyone: submissions are stored, and
the notice goes to the bell. To mail people when a form is submitted, add a `notify`
handler on the Handlers page whose recipients name them - usually a group, e.g.
`[{"groups":["site-owners"]}]` (SM1413), with the addresses set on each account on the
Users page - and add it to the form's targets after the handler that stores the
submission. Then delete the `owner_contact` line. `lazysite check` names a site that
still sets it. A form's acknowledgement to the submitter (`acknowledge_field`) is
unchanged.

**A new capability, `publish_copies`, held by nobody (SM1354).** Pages can be copied,
changed and published over the original. A person in the manager publishes with
`manage_content`, as they save today. An agent publishes over MCP or the control API
only with `publish_copies` as well, which the upgrade grants to no group: the manager
groups' top-up and `lazysite check` leave it out by design, and a manager group is
offered it to grant. Grant it to an agent's group only where the site has decided an
agent may publish its own change. The copies live in `lazysite/copies/`, which content
history leaves out; nothing else changes on upgrade.

**Row changes are recorded (SM1355).** From this release every row save, delete and
switch is recorded in the data store, in a table named `_row_changes` that the first
recorded write creates; nothing needs migrating. The history is kept 90 days unless a
table's descriptor sets `row_history_days`. Where the daemon runs, its new daily job
`row-history-prune` removes expired changes from a store nobody writes to, as the
existing `daemon_job_user`; it needs no grant beyond `run_jobs`. A table gains a switch only when its
descriptor names an `availability` field, and wizards exist only where
`lazysite/db/wizards/` holds them, so an upgraded site's tables and pages behave as
before.

**The sitemap and llms.txt list every public page (SM1357, ruling 165).** Until now they
listed only pages whose front matter said `register: [sitemap.xml]` (or `llms.txt`).
From this release a page with no `register:` key is in both, so on upgrade the sitemap
and the summary grow to the site's whole public content. A page that has a `register:`
list keeps what it says, and one that names either the sitemap or `llms.txt` is now in
both (ruling 174: the two list exactly the same pages); a protected, draft, copied,
`api:`/`raw:`, redirect or starter demonstration page and the engine's sign-in and error
pages are never listed. On a multi-site docroot the bare host lists no folder that looks
like another site's content - one under `sites/`, or one holding its own `lazysite.conf`
- that is not a declared `content_root` (ruling 171); the bare host still serves it, and
`lazysite check` names each such folder: declare it as a domain's content root or move it
out of the docroot. To keep a
page out, give it `search: false`, or a `register:` list that does not name the
registry. `llms.txt` is on by default (a site that had no page registered for it now
has one listing its pages); `llms_txt: off` in `lazysite.conf` turns it off. An existing
site's `llms.txt.tt` is its own and is not replaced: the *About* section the new
template prints from the organisation details appears on a site only once its template
is taken from the starter (`starter/lazysite/templates/registries/llms.txt.tt`).

**A row written refreshes the pages that show it (SM1357).** A page binding a table with
`db:` and carrying a `ttl:` used to show a changed row only when the ttl ran out; it now
renders again on its next request after any row write the engine makes (each table has a
change stamp in `lazysite/db/stamps/`, made on first use). A row changed outside the
engine (an `sqlite3` shell) touches no stamp and still waits for the ttl.

**Schedules and the site's time zone (SM1356).** New and opt-in: a table is a schedule
only when its descriptor says `schedule: true`, and `time_zone:` defaults to UTC, which
is what every date in the engine already was. A site with dated rows or a schedule sets
`time_zone:` to its zone (the host needs the `tzdata` package, which `lazysite-common`
now recommends, so an install that skips Recommends must add it; `lazysite check` names a
zone it cannot find). Passed exceptions are removed by the daemon's new
`schedule-exceptions` job, which runs as the job account and needs `manage_data` on it;
without that grant the job records a refusal and the exceptions stay, harmlessly.

**The editor holds its lock again (SM1411).** The manager's editor now takes and renews
its edit lock with a POST, so opening a file no longer shows "This action must be sent
as POST." beside the toolbar, and a second editor on the same file is told who has it.
Nothing to do but the upgrade, which replaces the page.

**Two roles reach an older site (SM1407).** On a site bootstrapped before 0.11.3 that
has the role bundles, the next Users or Groups page load adds the `analysts` and
`lead-readers` roles it lacks, with no members, nested into their bundles as on a new
install (and the `cap-audit` bundle with `analysts`). Nobody's access changes until an
operator puts an account in one. A role deleted after it was added stays deleted.

**An import with no valid row is refused (SM1410).** `accounts-import-stage` and
`stage_accounts` given only invalid rows now answer `ok: 0` with the same `invalid`
list and no id, and keep nothing; before, they answered ok with an id and kept an empty
run. A script that staged and then checked `staged` needs no change; one that took `ok`
alone as "kept" now sees the refusal. Empty runs kept by earlier releases stay in the
import list until removed there.

## Odoo's modules leave core's lib, and the rest of 0.16.7

**Odoo's modules leave core's lib (SM1369, X7 part one).** The Odoo extension's Perl
modules now install beside its descriptor, in `{DOCROOT}/../extensions/odoo/lib/`, and
no longer in `{DOCROOT}/../lib/Lazysite/`. The upgrade does it: it installs the new
copies, removes the old ones and the directories they leave empty, and rebuilds the
extension hook index. Nothing a site configures changes: the extension's conf entry,
`odoo.conf`, the `lazysite/odoo/` store, the bindings, the cookies (nobody is signed
out), `/cgi-bin/lazysite-odoo.pl`, `/assets/lazysite-odoo.js`, `/odoo-signin`, the
actions, the MCP tools, the capabilities and oomd's socket all stay as they are.

If a site **edited** one of the old module files, the upgrade keeps that file and
names it in its summary, under `Orphans: N (edited post-install, left in place):`,
as `- {DOCROOT}/../lib/Lazysite/Odoo/<Name>.pm`. Odoo then refuses to load rather
than run the stale copy, and the error the web server logs names the file:
`Lazysite/Odoo/<Name>.pm is in the payload lib .../extensions/odoo/lib and also at
.../lib/Lazysite/Odoo/<Name>.pm - a copy an earlier release left outside the
extension; remove it`. Keep any change you need from that file (the released copy
is in `extensions/odoo/lib/`), delete the named file, and Odoo answers again; no
restart is needed. A site that edited none has nothing to do.

Odoo still ships in the same package as the engine. The separate package is 0.16.9.

**A stale Odoo site session is renewed, not refused (SM1381).** On a site with
`odoo_site_signin: on`, a person idle past `odoo_identity_ttl` who opens a protected
page now passes through `/cgi-bin/lazysite-odoo.pl?renew=1` and back to the page. If
Odoo has ended their session they reach the site's sign-in page instead
(`auth_redirect`, else `/login`), with `next` kept; `/login?action=session` goes
through the same step. The step needs no configuration. A front end that sends
`/cgi-bin/lazysite-odoo.pl` to the engine already sends it there. The step sets a
short-lived cookie, `lzs_renewed`, which stops a loop: one renewal a minute, then the
sign-in. The refusal is logged at INFO.

**Deleting a group is refused while anything names it (SM1387).** The Groups page's
Delete, and the new `group-delete` (control API) and `delete_group` (MCP), refuse a
group a page, an access rule, a domain, a data table, a binding or a connector still
names, and say which: remove the group from those first. A group with a member is
refused too. The operator group is never deleted, even when there is more than one
(before, only the last was kept). A domain-confined token or MCP grant deletes only a
group it created with `group-set`. An empty agent role (SM1371) may be deleted;
`reset-groups` restores a shipped one. Each deletion is audited.

**An account named `v1` cannot hold a session, and cannot be created (SM1390).** `v1`
is the theme-preview cookie's marker, and a session payload beginning with it is
refused, so a site with an account of that exact name has it sign in and be refused on
every request: `lazysite check` names it; rename it (`users rename v1 NEW-NAME`). The
users tool, the manager and an accounts import refuse the name from now on. A session
cookie whose issue time is more than 300 seconds ahead of the server's clock is
refused as well; a host whose clock runs that far ahead of the one that minted the
cookie sees sign-ins refused until the clocks agree.

**A hand-written schedule entry under the 300-second floor is now reported (SM1391).**
It never ran before and still does not; `lazysite check` names it, and the daemon's
run record (`lazysite/daemon/schedule-runs.json`) holds a refusal for it, written once
and logged. Set `every:` to 300 or more.

**The agent roles and the shipped bundles appear on an older site (SM1393).** 0.16.6's
note said the four agent roles appear on a site's first Users or Groups page load after
the upgrade. On a site bootstrapped before the `seeded` mark existed (before 0.11.3, or
whose manager group came from `lazysite.conf`'s `manager_groups`) they did not, and nor
did any bundle a release had added since (`cap-tidy`, `cap-services`,
`cap-maintenance`, `cap-audit-switch`, `ch-files`, as the site's roles draw on them).
After this release, the first Users or Groups page load (or any users-tool command
that reads the group store, such as `group-add`; the CLI `groups` listing is not one)
adds the four roles and, on a site that has the bundle layer, the bundles it lacks,
nested into the roles present under their shipped names. The roles have no members and
the bundles are nested only into roles already there, so nobody's access changes;
delete any you do not want and it stays deleted. A group an operator made under a
shipped name on a site that carries the mark is left alone, as before. The site's
audit log records each adoption. On such a site `reset-groups` and the Groups page's
"shipped" badge still read the mark, so they answer for the roles as they did.

**A form's own conf opens in the manager's editor (SM1392).** An account holding
`manage_forms` can open `lazysite/forms/<name>.conf` in the editor from the Files page;
without the capability the server's refusal names it. Over MCP, `read_file` and
`write_file` on that path now ask `manage_forms` rather than `manage_content`: a grant
holding `manage_forms` without `manage_content` reaches a form's own conf through the
connector as it has over WebDAV; a grant holding `manage_content` without `manage_forms`
is refused it, as it was. If an account holds `manage_forms` it should not, this is the
release to check. No other path changes. From ruling 152 the tool listing offers
`read_file` and `write_file` to a grant holding `manage_forms` without `manage_content`,
each saying it reaches a form's own configuration and nothing else, and
`whoami.tools_by_reach` names that reach under `path_only_reach`.

**A check line that goes away (SM1389).** On a site with a protected folder's history
on (`history: true`, SM1324), 0.16.6's `lazysite check` reported the history repository
in the private store (`<store>/lazysite/git`) as stray public copies of the docroot's
`lazysite/git`, and the site NOT SERVICEABLE. The walk now skips that one repository;
nothing to do. A layout a rule moved into the store, and a copy beside it, are still
reported.

**Smaller changes, nothing to do.**

- A theme is deleted by its path, under any layout (SM1385): `delete_theme` (MCP),
  `theme-delete` (control API) and the manager's Themes page take
  `lazysite/layouts/<layout>/themes/<name>` as `theme-copy` does; the bare name still
  means the active layout's theme, and the same refusals apply by path (the active
  theme, a theme a domain serves, a theme another account made, a path into a served
  copy). The Themes page offers Delete under every layout.
- A theme install warns when its stylesheets are outside `assets/` (SM1386), on every
  install door (`theme-upload`, MCP `install_theme`, the layout installs), naming each
  stylesheet and where it belongs; warned, never refused. Only `assets/` is served, so
  such a theme previews with no CSS until the files are moved.
- A rule with `history: true` on a folder that does not exist yet is refused with a
  sentence that says so and to create the folder first (SM1388); it said "is not a
  folder", which read as a file.
- Live data is a scheduled connector answer in a table row (SM1382): the "Live data"
  section of `/docs/ai-briefing-building-sites` is the recipe, with its measured limits
  (a 300-second floor, an interval rounded up to a multiple of 300, fixed fields, one
  row per poll, `ttl:` the only freshness bound). A connector cannot express a
  submit-poll-read job protocol; that is filed as SM1384, a candidate.
- The session cookie's format is an external contract (SM1383):
  `docs/architecture/session-cookie-contract.md` states what an outside process on the
  same host verifies, read-only, and the format changes only versioned, reader before
  writer. Nothing changes for a site. A site that gives a process read access to its
  `auth/` directory trusts it as far as the web server, because the key is symmetric
  (OBLIGATIONS.md).

## The primary's content leaves out the other domains, and the rest of 0.16.6

**The primary site's content leaves out the other domains' folders (SM1372).** On an
instance serving more than one domain, each secondary domain's content lives in its own
folder under the document root (`sites/<host>/` as a rule). Until now an account that
reaches the primary site - one granted nothing (no domain names its group), or one whose
group is on the primary's row - reached those folders too, through the primary's
content: over WebDAV, MCP, the control API and the manager's Files. From this release it
does not (ruling 126): the primary's content is the document root less the other
domains' content roots. What it is refused says which folder and how to grant it. Nor
does it see them listed (ruling 137): the manager's Files, MCP `list_files` and a WebDAV
PROPFIND of `sites/` leave out each other domain's folder the account is refused, so a
client that synced the whole tree over WebDAV no longer finds them there.

Unchanged: the operator (a member of the operator group, the group `setup-sysop` makes,
in the manager or over WebDAV) still reaches every folder, and an account already
granted a secondary domain keeps that domain.

Who loses something: any other account - a manager holding `manage_users` but not in
the operator group included, and often an agent's token or WebDAV login - that edited a
secondary domain's pages through the primary, without being granted that domain. Before
upgrading, find them: any non-operator account that writes under `sites/` and whose
group is named in no `alias.<host>.allowed_groups` line for that host.

How to give it back: grant the domain. Name the account's group in that domain's
`allowed_groups` (the Domains page, or `domain-set` with the access keys, or
`alias.<host>.allowed_groups: <group>` in `lazysite.conf`). Grants add, but naming a
secondary takes away the primary that an account granted nothing had: to keep the
primary as well, name the group on the primary's row too (the bare
`allowed_groups: <group>` line; the Domains page row `(default)`).

**The data endpoint, and the control API's `data-rows`, refuse a parameter they do not
read (SM1377, rulings 131 and 139).** A page's own script that reads
`/cgi-bin/lazysite-data.pl` with a query parameter other than `table`, `order_by`,
`order`, `limit`, `offset`, `csrf` or `_` now gets a 400,
`{ ok: 0, kind: "unknown-parameter" }`, naming the parameter, where the parameter was
ignored and every row came back. A call to `action=data-rows` with a query parameter
other than those it reads (`table`, `order_by`, `order`, `limit`, `offset`) or `_` and
`csrf_token` gets the same refusal. The shipped `lazysite-data.js`, a page using
`data-ls-db`, the manager's Data page and MCP `read_data_rows` are unaffected.

Who is affected: a custom script or a token client that adds its own parameter, such as
a filter (`chunk=AAA`, which never filtered) or a cache-buster under another name.
Before upgrading, search the site's scripts for `lazysite-data.pl?` and token scripts for
`data-rows`. Filter on the page binding (`db:t(chunk=AAA)`) or in the script after
reading the rows, and name a cache-buster `_`.

**`manage_forms` reaches a form's config on more doors, and four agent roles appear
(SM1371, ruling 122).** An account holding `manage_forms` can now read and write
`lazysite/forms/<name>.conf` through MCP `read_file`/`write_file` and the manager's file
editor, as it already could over WebDAV. The file's targets must name existing handlers.
`smtp.conf`, `handlers.conf` and `schedule.conf` stay closed to every grant. If an
account holds `manage_forms` it should not, this is the release to check. The first use
of the users tool after the upgrade (any Users or Groups page load) adds
`content-agent`, `data-agent`, `forms-reader` and `analytics-agent` to a site that has
the shipped roles and lacks them. They have no members, so nobody's access changes;
delete any you do not want and it stays deleted. To move an agent onto a role, put it in
the role on the Groups or Users page and take the matching capabilities off its own
`role-<account>` group; the Users page shows what an account holds beyond its roles.

**A script that reads the audit trail's actor for an Odoo call (SM1366).** A call made
under a person's Odoo session, on a request also signed in to the site, is recorded and
audited under that site account (a local account, or `odoo:<login>`), with the session's
hash beside it (`session` on the call record, `session=` on the audit row), where the
actor was `session:<hash>`. A filter or report that keyed on `session:` for those rows
reads the account instead. With no site identity the hash is the actor, as before.

**Smaller changes, nothing to do.**

- The extension hook index (SM1369). Every upgrade and reinstall rebuilds
  `lazysite/extensions.index.json` from the enabled extensions' descriptors, as the site
  user, after the other steps. A site whose extensions declare no hooks, which is every
  site today, gets no index and the summary says nothing about it. An enabled extension
  that declares a hook this release does not build is named in the summary as
  `hooks refused: <id> (...)`, with the slice that builds it, and runs nothing. If the
  rebuild cannot write the index, the summary warns under `HOOKS:` and the previous index
  stands. Enabling or saving an extension in the manager rebuilds it.
- Existing tokens (SM1370). A token's capabilities are its account's grant at each
  request, as every token door already resolved them (measured on 0.16.5), so no
  existing token gains or loses anything at the upgrade; `whoami` now says so in a
  `grant` block. An agent whose client shows an old tool list after a grant lists its
  tools again, or reconnects the connector; it needs no new pairing key, and rotating a
  token changes nothing about its grant.
- A form can tell its owner by email, and answer the submitter (SM1362). Both are off
  until set: `owner_contact:` in `lazysite/notify.conf`, and a form's
  `acknowledge_field` and `acknowledge_message`. Both send through the Form SMTP
  extension's settings. A site that sets `owner_contact` for a `notify: full` form mails
  the submission's fields to that address, and accounts for it (OBLIGATIONS.md).
- An extension's settings read (`extension-read`) answers only the keys that extension
  declares, never the rest of `lazysite.conf` (SM1373).
- A plan Odoo refused tells the visitor Odoo's own words for a validation error, and a
  plain sentence otherwise (SM1374); the counts stay in the journal and the log.
- The shipped 403 page lists the groups a page needs as a list (SM1375). A site with its
  own `403.md` is unchanged.
- Installing, activating or binding a layout whose `layout.json` says it needs a newer
  engine answers with a warning naming both versions, and goes ahead (SM1378).
- A form's quarantine leaves email fields out of the "same value in every field" rule,
  and quarantines an email field holding quotes or SQL-shaped text (SM1379); one
  apostrophe in an address's local part passes.

## Address lists become address profiles, and the rest of 0.16.5

**Address profiles (SM1343-SM1345).** Address lists are now address profiles. The
upgrade to 0.16.5 converts `lazysite/auth/address-lists.json` to
`address-profiles.json` once: the same names and entries, with no allow or deny
kind. The old file is kept as `address-lists.json.converted`. The same step renames
`visitor.in_list` / `visitor.in_any` to `visitor.in_profile` /
`visitor.in_any_profile` in the site's pages, layouts, themes, templates and private
store, and lists each file it changed. Whether a profile allows or denies is now set
by the rule that names it: `addresses` allows, `addresses_deny` denies.

After upgrading, run `lazysite check`. It names:

- any rule that now allows a profile that was a deny list, or denies one that was an
  allow list. Such a rule was possible only by hand-editing; it refused every
  visitor before, and now does what its key says;
- any template call still using the old names, which now always answer false;
- an old store the upgrade could not convert. Until it is converted, every rule that
  names a profile refuses.

Scripts and agents: the actions are `address-profiles`, `address-profile-set` and
`address-profile-delete`, the MCP tool is `list_address_profiles`, and the users-tool
commands are named the same way (no `--kind`). The old names, and a `kind` sent, are
refused with a message naming the new spelling.

**The bad-URL blocker (SM1321).** A request for a file the site really has is never
counted, and loopback (127.0.0.0/8, ::1) is always exempt. `bad_url_exempt` names
address profiles whose addresses are exempt too; `bad_url_exempt: none` takes
loopback's exemption away. If a front end on the same host (a reverse proxy on
127.0.0.1) forwards to the engine, name it in `trusted_proxies` (`127.0.0.1`): the
default trusts the private ranges only, so until then every visitor is the proxy,
loopback, and the blocker counts nothing. Before 0.16.5 the same site refused every
visitor once a theme's scripts under `vendor/` were requested often enough.

**A site with its own `login.md` (SM1322).** The shipped sign-in page asks the server
whether the session is still honoured before it says "You are already signed in". A
site's own `login.md` carries that only if its signed-in panel has the
`data-ls-auth-check` attribute; add it, and the "Sign in as someone else" link
(`/cgi-bin/lazysite-auth.pl?action=logout&then=signin`, with the page's `next`), as
the shipped page has them.

**Theme copies under `/lazysite-assets/` (SM1335, SM1336, SM1339).** A theme's served
copies now follow its source: a write to `lazysite/layouts/<layout>/themes/<theme>/`
reaches every host's copy at once, with no activation. A write into a copy itself,
on any surface and for the operator too, is refused, naming the source to write
instead. The theme and the layout a secondary domain serves are read-only, as the
primary's are: copy, edit, then activate with `host`. A script or agent that wrote
into `/lazysite-assets/` or edited a domain's active theme in place must change.
A theme whose `assets/` holds a symbolic link or a file the web server would run is
not copied; the log and the write's answer name the entry to remove.

**Connect an AI assistant is public (SM1341).** `/docs/ai-connector-setup`, which
says how a client connects and authenticates, no longer needs a sign-in. It names no
site's accounts or credentials. A site that wants it signed-in puts an access rule on
`docs/` or a page of its own at that path.

**Smaller changes, nothing to do.** A protected folder may keep a history
(`history: true` on its rule, SM1324) and a site may audit agents' reads
(`audit_reads: on`, SM1325); both are off unless set. MCP `write_file` takes an
optional `base_mtime` and refuses a write over a newer version (SM1327). The Odoo
extension's `odoo_display_name` names Odoo in what a visitor reads (SM1328). A page
refused by an `auth/acls.json` read list now gets the site's 403, naming the list's
groups, never a user on it (SM1365). A grant on a secondary domain no longer takes
the primary away, and an account scoped today keeps exactly its reach (SM1332-SM1334).

## Plugins become extensions, on disk and in lazysite.conf (SM1142)

The upgrade to 0.16.4 moves each site in place, once, and the result is in its
summary under `Extensions:`:

- the files left in `{docroot}/../plugins/` move to `{docroot}/../extensions/`.
  A copy of a shipped file the site edited is replaced by the release's, as an
  edited code file always is, and the edit is kept beside it as
  `extensions/<file>.pl.from-plugins`; a file the site added itself moves as it
  is. The emptied `plugins/` is removed (on HestiaCP by the root-run deploy);
- `lazysite.conf`'s `plugins:` list becomes `extensions:` and each
  `- plugins/<file>.pl` entry `- extensions/<file>.pl`, so every extension that
  was on stays on - the login rate limiter among them;
- a cgi-bin link into `plugins/` is pointed at the moved file, and an account
  whose start page was the Extensions page keeps it at its new address.

Nothing reads the old names afterwards. `lazysite check` names a `plugins:` list
or a `- plugins/...` entry written back by hand, by line.

**What you check yourself** - references the upgrade cannot see, made by hand
from older docs:

- a crontab or script running `perl .../plugins/stats.pl --classify` or
  `--export`: it is `extensions/stats.pl` now;
- a pipe to `perl .../plugins/form-smtp.pl --pipe`: `extensions/form-smtp.pl`;
- a `cgi-bin` link you made yourself outside the site's cgi-bin;
- a bookmark to `/manager/plugins` or `/manager/plugin-config`: the pages are
  `/manager/extensions` and `/manager/extension-config`, and the old addresses
  are not kept;
- a script calling the manager or control API as `plugin-list`, `plugin-read`,
  `plugin-save`, `plugin-action`, `plugin-enable` or `plugin-disable`, or passing
  `?plugin=`: those are refused now, naming the `extension-*` action and the
  `extension` parameter to use. `extension-list` answers under `extensions`;
- an audit or log filter on the old names: from 0.16.4 the audit writes an
  extension action's row as `extension-*` (`extension-save`, `extension-action`
  and the rest; rows written before stay `plugin-*`), SM831's
  `spelling=deprecated` flag is gone with the old spelling, and a disabled
  extension's refusal logs as `extension-gate` (was `plugin-gate`). Match both
  spellings until the old rows age out.

## Starter pages are opt-in for new sites (SM1285, SM1286)

Nothing changes on an existing site. Its starter pages are kept: the demos, the
sample contact and members pages and the starter's welcome page. A site
provisioned from now on gets none of them unless `provision --starter` asks. It
has the system pages, the site search, the `/docs` manual and a minimal home page
that the engine serves until the site writes its own `index.md`.

To clear out the starter pages a site never edited:

```bash
lazysite starter --docroot /path/to/public_html --list
lazysite starter --docroot /path/to/public_html --remove-unmodified --dry-run
lazysite starter --docroot /path/to/public_html --remove-unmodified
```

An edited page is never removed. A menu entry left linking a removed page is
named in the output, for you to edit.

## The /docs manual moves into the engine (SM1284)

The whole `/docs` manual, the agent briefings included, now ships in the engine
tree (`lazysite/templates/docs/`) and is served from there whenever the site has
no page of its own at the path. Upgrades refresh it, and clearing a site's
content leaves it in place.

What the upgrade does to a site's `docs/` folder:

- **A page the site never edited is removed**, along with its cached render.
  The install state's checksum says it is unchanged, so the engine's copy now
  serves at the same URL.
- **An edited page is kept** and named in the output as `orphan (edited
  post-install, left in place)`. It still serves in place of the engine's page,
  and `lazysite check` warns that it shadows a newer version. Delete it to serve
  the engine's page, or keep it as a deliberate override.
- **A page the site wrote itself is untouched.** So is everything outside
  `docs/`, the starter pages included.

The manual stays out of the site's search, sitemap, feeds and `llms.txt`. Set
`engine_docs_public: true` in `lazysite.conf` on a site that should list it,
such as the product's own documentation site.

## The visitor's address, if this site is behind a reverse proxy (SM929)

Nothing to do on a site served directly: the engine reads the connecting address,
exactly as before.

**A site behind a reverse proxy needs two things, and until both are present every
address the engine records is the proxy's** - the `_ip` on a form submission, the
audit trail's actor column, the login and form rate-limit buckets, the bad-URL
auto-blocker and the daily visitor count:

1. **The proxy must send the visitor's address.** The shipped nginx templates now
   do (`X-Forwarded-For`, template revision `2026-10-01`). A template reaches a
   site only when Hestia rebuilds that site's vhost, so the rollout table's VHOST
   column reads `rebuild` until it has been - that column is how you tell which
   sites are still on the old template.

   **Hestia renders a vhost from its OWN copy of the template, not from the
   package's** (SM1196). That copy is put there by hand once, so an upgrade used
   to leave it old and every `v-rebuild-web-domain` re-rendered the old template:
   edge's installed `lazysite-proxy` predated SM929 and kept passing the client's
   `X-Forwarded-For` through after a rebuild. `lazysite-hestia-update-all.sh` now
   compares each lazysite template in Hestia's directories (the nginx
   `lazysite-proxy`, and `lazysite-app`, `lazysite-cgi`, `lazysite-fcgi` where
   installed) with the release's on EVERY run, replaces one that differs (the old
   copy kept beside it as `NAME.EXT.bak-TIMESTAMP`, which Hestia does not offer as
   a template), names the domains that render it until rebuilt, and rebuilds them
   with `--rebuild`. A refresh that fails is a FAILURE line and exit status 1. On a
   host that only has the packages, copy the templates again after every upgrade
   (`lazysite-hestia-domain` says when its copy is STALE). To check the result:
   `grep -n "X-Forwarded-For" /usr/local/hestia/data/templates/web/nginx/lazysite-proxy.*tpl`
   must match in both files, and a request sent with `X-Forwarded-For: 192.0.2.55`
   must not be seen as 192.0.2.55.

   **`--rebuild-exposed` rebuilds only the sites at risk** (SM1265). A site whose
   vhost still passes the client's `X-Forwarded-For` through, and which trusts
   forwarded addresses (`trusted_proxies` absent, empty or a list), is a FAILURE:
   any visitor chooses their address. With `--rebuild-exposed` the rollout
   rebuilds those sites, and no others, after it has refreshed Hestia's template
   copies and before it deploys, so the deploy's permission pass and the repair
   put back what the rebuild resets (SM270). Each one is logged as `auto-rebuilt`.
   Without the flag the FAILURE line names it. It cannot be combined with
   `--list`, which changes nothing.
2. **The engine must be told the proxy is trustworthy.** `trusted_proxies` on the
   Config page, or in `lazysite.conf`. Absent or empty means the private ranges
   `10.0.0.0/8`, `172.16.0.0/12` and `192.168.0.0/16`, which covers a proxy on a
   private address and needs no action. **If your front end is on this machine,
   name it** - `127.0.0.1` is not trusted unless you say so. `trusted_proxies:
   none` ignores forwarded headers entirely.

`lazysite-check` reports an entry it could not parse, and says when the setting
resolves to no trusted address at all.

**One consequence worth knowing before you enable it.** Where a site previously
recorded one private address on every submission, it will now record the
visitor's real address - which is personal data where the proxy's address was
not.

**That is a decision, not an oversight** (ruled 2026-10-01): the address is kept
in full because it is what abuse handling needs - an operator who wants to block
or report a source has nothing to act on without it, and the nine submissions
that produced this filing were indistinguishable from each other precisely
because the address identified nobody. Truncating it the way the visitor log does
would reproduce that problem one octet higher up. The two stores differ on
purpose: counting distinct visitors needs no identity, and handling abuse does.

## Upgrading to 0.13.13 from 0.13.12

**This release breaks how form delivery is written, and converts it for you.**
It is the change the 0.13.x line was built towards: a form calls a named
**handler**, the timer calls handlers too, and there is one way to say where
data goes (SM842).

What the upgrade converts, once, by running `lazysite-handlers.pl convert`
from the newly installed tree (it prints what it changed):

- **`webhook` and `api` handlers** become **connectors** - with the webhook's URL
  and body format, public invocation, and no rate cap, as the webhook had - and
  the handler becomes a `connector` handler naming it.
- **`db` handlers** become `table` handlers with `keep_copy: false`.
- **Inline targets in a form's config** (`- type: file`, `- type: webhook`)
  become named handlers, reusing one that already delivers to the same place.
  An inline target in a form that ALSO names a handler never delivered - the old
  reader ignored it - so it is dropped, not woken up.
- **A connector's own schedule** (`schedule_every`, `schedule_payload`) becomes an
  entry in the new `lazysite/forms/schedule.conf`, calling a connector handler.

What it cannot convert, and says so in the upgrade summary: a **webhook to a
plain `http://` URL on another host** - a connector sends over https, or http to
this host only. That handler delivers nothing until its URL is changed and the
conversion is run again (`lazysite-handlers.pl convert --docroot <docroot>`, as
the site user). `lazysite check` reports any shape the conversion left.

What changes for people and agents:

- Handlers are configured on the new **Handlers** page (System), not in the Form
  Handler's section of Extension Config; the submissions viewer stays there.
- **Who may make a handler depends on where it sends**: a table handler needs
  Data (`manage_data`), a connector handler needs Connectors
  (`manage_connectors`), email and file handlers need Forms (`manage_forms`).
  Binding a form to an existing handler needs Forms alone. Handler actions are
  now available to token clients too.
- MCP's `list_form_handlers` is **`list_handlers`**; `bind_form` takes a handler
  (or `handlers`) and no inline `target`. A form config written over WebDAV whose
  targets are not existing handlers is refused with 422.
- A connector save carrying `schedule_every` or `schedule_payload` is refused by
  name - schedule it on the Handlers page instead.
- The daemon's `connectors-call` job is replaced by `schedule-run`. Its job
  account needs the capability of each scheduled handler's destination.

**Three settings that were kept alive for one release are gone** (pre-stable:
one way to say each thing). The upgrade converts the configuration and says so:

- `manager_upload_blocked_paths` in `lazysite.conf` is renamed to
  `manager_blocked_paths`, its name since SM019c. Where both were set the old
  line is dropped - the new key already won.
- `db_render_raw` is deleted. `db:` values are always escaped (SM786); a site
  that had it on is warned in the upgrade summary, because a value that carried
  HTML now shows it as text.
- `form-list` (and MCP `form_list`) returns the submission count as `row_count`
  only; the `rows` alias for it is gone. `rows` is the array of submissions in
  `form-submissions`, which is why the count needed another name.

`lazysite check` reports either key if it comes back.

**Control API refusals now carry an HTTP status** (SM670). A client of
`/cgi-bin/lazysite-manager-api.pl` that treated every response as 200 sees 403,
404, 409, 413, 429, 207 or 400 on a refusal - by the refusal's `kind`, listed in
`docs/ai-connector-tools.md` under the error model. The JSON body is unchanged
and still carries `ok: false`, so a client that reads the body, as the manager's
own pages do, is unaffected. A client that stops on a non-2xx status before
reading the body should read it anyway: that is where the reason is.

**`whoami` separates what an account may do from what it is** (SM821), on both
the control API and MCP. `capabilities` now holds only the capability keys, and
`ui` in it means manager access (what `manager_ui` meant - that key is gone).
Everything else moved to a new `account` block: `groups`, `email`,
`display_name`, `created_by`/`created_at`/`managed_by`, token and MFA state,
scopes, and `interactive_login` - the setting that `ui` used to report over the
control API. The control API's `partner` is now `user`, as on MCP. A client that
read `capabilities.ui` as "may sign in", `capabilities.email` or top-level
`groups` reads `account.interactive_login`, `account.email` and `account.groups`.

**Login rate limiting is now an extension, and the upgrade switches it on**
(SM798). `plugins/login-rate-limit.pl` is listed in every site's `plugins:` list
by the first upgrade that carries it, and on every fresh install, so nothing
changes for a site unless its operator switches the extension off. Switched off,
sign-in attempts are not counted and no counter is kept; the sign-in log and
`lazysite check` both say the limiter is NOT in force, as they do when DB_File
is missing (Debian: `libdb-file-perl`, now the extension's declared dependency).
The upgrade does this once: switch it off afterwards and it stays off.

**Re-render your vhost** (SM797). The shipped front-end templates now hand a
page's markdown, `.url` and `.brief` files, backups, config, keys and executable
source to the engine instead of serving them from disk - so `/about.md` renders
the page and a stray `config.bak` is *not found*, whether or not the site has an
ACL store. A package upgrade does not rewrite an installed vhost: run
`lazysite-apache-vhost add` or `lazysite-nginx-vhost add` again for the domain
with the options it was added with plus `--force` (an existing vhost is refused
without it), or rebuild the domain in Hestia (which re-applies both the web and proxy
templates). If you maintain your own vhost, apply contract item 5 in
`docs/reference/webserver-wiring.md`. On a multi-domain instance, regenerate the
per-domain block (`... rewrites --docroot <docroot>`) as well.

The same re-render carries a second fix (SM850): the rule that hands existing
files to the engine once a site has an ACL store now also looks for the store
beside the docroot, where it is on a site whose engine tree was moved out
(`lazysite migrate-engine-tree`). Before, that rule never fired on a migrated
site, and the front end served its static files from disk whatever the ACL said
- the private store still held back what had been moved into it. If you
maintain your own vhost, apply contract item 7 in the same reference.

**On Hestia, the rollout now tells you what is left** (N13-41..43). The table
`lazysite-hestia-update-all.sh` prints first has two new columns:

- **ENGINE** - where the site's engine tree is: `inside` the docroot, `outside`
  (migrated), or `BOTH`, a half-finished migration, which is always a fault.
- **VHOST** - whether the vhost Hestia rendered for the site carries this
  release's template (`current`) or an older one (`rebuild`). Every shipped Hestia
  template now carries a `# lazysite-template-rev:` line for this. Every site
  reads `rebuild` on the first rollout of 0.13.13, because no earlier template
  had the line - which is also true: none of them has this release's rules yet.
  Run the rollout with `--rebuild`, or `v-rebuild-web-domain USER DOMAIN` per
  site, and the column turns `current`.

The summary at the end adds **CHECK** - `lazysite check` for each site that
updated, as `clean` or its warning and failure counts - and VHOST as it stands
after the run, with a count of the sites still to rebuild.

The Hestia scripts also stop assuming the engine tree is inside the docroot. On
a migrated site the rollout used to read the version as `?` and the channel as
unset, the lister flagged `NO-INSTALL-MARKER`, and the deploy treated every
upgrade as a first install - re-applying the template, rebuilding the vhost and
re-running the setup-manager step - while its permission sweep and secret
lockdown went to a directory that was no longer there. They now find the tree
where it is. `update-all` requires the lister it ships with; the fallback that
searched `/home` for install markers is gone.

## Upgrading to 0.10.19 from 0.10.18

**This is a BETA build** - the first promotion off the edge line. A site takes
it only if its `update_channel` accepts beta or below; nothing changes for a
site set to `stable` or `certified`.

**No new operator action.** Two fixes are worth knowing about because they
change behaviour you may have worked around:

- **Access rules now travel with content on every surface.** Deleting content
  drops its rules (previously only over WebDAV); moving content carries them.
  If you have been re-applying rules after a move, you no longer need to.
- **The access-rule store stays writable by the manager after a deploy.** If
  you saw `acls.json ... is not writable by the CGI` repaired on every upgrade,
  that was a real fault and it is fixed.

**Coming from 0.10.14 or earlier: the 0.10.15 section's four manual steps
remain your list.**

## Upgrading to 0.10.18 from 0.10.17

**No new operator action, and one thing that now happens for you.** From this
release an upgrade INVALIDATES RENDERED PAGES (SM413): cached pages re-render
on next request, so the first page you check after upgrading reflects the
build you just installed. Before this, a page whose source had not changed
kept its pre-upgrade render indefinitely - a homepage was found serving the
same render through four deployments.

Also automatic: the outside-in ACL probe now drops to the site's owner instead
of refusing when the deploy runs as root, so `lazysite probe` produces a
verdict rather than "NOT CONFIRMED" (SM426).

**Worth knowing:** this release fixes a CRITICAL issue where an authenticated
content editor could write outside the content area (SM418). No action is
needed beyond upgrading.

**Coming from 0.10.14 or earlier: the 0.10.15 section's four manual steps
remain your list.**

## Upgrading to 0.10.17 from 0.10.16

**No new operator action.** The multi-domain apply fix (SM412), the plugin
enabled-gate (SM409 - gates only contract-declaring plugins, of which none
ship yet), and the session-verification module move (SM411) all travel in the
package with behaviour preserved for existing sites. New diagnostic worth
knowing: `plugins/stats.pl --classify --path P [--ua UA] [--status N]
--docroot D` answers the visitor classifier from the command line without
touching the stats.

**Coming from 0.10.14 or earlier: the 0.10.15 section's four manual steps
remain your list.**

## Upgrading to 0.10.16 from 0.10.15

**No new operator action.** Everything 0.10.16 changes travels in the
package: build provenance in the release manifest (SM400), structured
form answers (SM401 - an authoring feature, nothing to migrate), the
form handler recording capture method instead of an unverifiable
identity (SM402 - existing stored submissions are unchanged; only new
submissions carry the new field), checked stats writers (SM404), and a
deterministic release gate (SM406).

**If you are coming from 0.10.14 or earlier, the 0.10.15 section below
is still your list** - its four manual steps (ACL re-apply, the proxy
template, the CSP decision, the front-door check) are cumulative and
none of them is superseded here. Do them once, at whatever version you
land on.

One thing to KNOW rather than do: from this release the artefact can
prove which commit its gate validated - `release-manifest.json` carries
`validated: {commit, files, tests}` and the repo's
`docs/releases/GATE-LOG.md` holds the matching row. If you verify builds
before rollout, that is the field to check.

## Upgrading to 0.10.15 from 0.10.10-0.10.14 (READ THIS ONE)

The package upgrade does the code. **Four things it cannot do**, and the
order matters.

### 1. Re-apply access rules, AFTER the upgrade

From 0.10.8 protecting content MOVES it out of the served tree - but
only on the act of protecting. Any section protected on an earlier
version still has its files in the document root, with the rule honoured
for pages and the files public.

```bash
lazysite acl reapply --docroot <docroot>
```

After the upgrade, never before: it re-issues stored rules through the
new code. It changes no rule. `NOT MOVED: <path>` in the output means
the rule was stored and nothing moved, which is the condition it exists
to find.

### 2. The proxy template, which a package cannot deliver

`lazysite-proxy` is a Hestia template. **A package upgrade does not
install or update one**, and 0.10.15 corrects a defect in it (SM374)
that returns **421 on every request** to a TLS domain.

::: widebox
**While the host's copy is stale the failure is identical to the bug.**
An operator who applies the fix, sees 421, and concludes the fix does
not work has been misled by their own template directory. Confirm the
copy on the host is the new one before drawing any conclusion from a
421.
:::

```bash
v-change-web-domain-proxy-tpl <user> <domain> lazysite-proxy
```

Test on the **body**, not the status: without a correct `Host` the
backend serves its default vhost with a 200, so a status check cannot
say which site answered.

### 3. The private store, if it does not exist yet

Creating it is a root action. `lazysite-check` reports whether the
engine can write to it; if the store is missing on a site that protects
anything, create it before re-applying rules.

### 4. Verify from outside, as the site user

```bash
lazysite check --check-acl https://<domain>
```

**Not as root.** The probe protects a fixture to measure it, and doing
that as root would leave root-owned files in the site tree - so it
declines and says so (SM377). The reason it gives is the one to act on;
the summary no longer overwrites it with a guess (SM385).

### Effective permissions widen if you are coming from 0.9.x

This has its own heading because it is a change of **who can read what**,
not a feature.

An `@group` entry in an ACL grants access to the members of that group.
Until SM288, MCP and the control API **discarded an account's groups**,
so those entries were silently inert on two of the three channels.
WebDAV honoured them; the others did not.

::: widebox
**Nobody gains groups here.** Partners already had them; two channels
were throwing them away. What changes is that an `@group` entry which
has been doing nothing on MCP starts doing what it says.
:::

Before upgrading a site that uses `@group` entries, see exactly who is
affected:

```bash
lazysite acl group-reach --docroot <docroot>
```

It lists each `@group` entry, the paths that grant it, and **every
account it reaches - including through nested groups**. Nested is the
case worth having: an account that reaches a group only by nesting is
precisely the one a quick look at the members list would miss.

If the report names an account you did not expect to have access,
resolve it before upgrading rather than after.

### What changed that you will see

- **A Content-Security-Policy now ships**, `report-only` by default.
  `csp: enforce | report-only | off` in `lazysite.conf`. **Do not set
  `enforce` yet** - the manager's controls use inline handlers a CSP
  hash cannot cover, so the manager is held at report-only regardless
  until they are converted.
- **Engine-served statics revalidate** rather than caching for a decade
  (SM387), and now carry an ETag so revalidation costs a 304 rather than
  a re-download (SM388). The ten-year cache was a property of the
  front-end fast path, not of lazysite.
- **402 and 403 pages** carry the full header set and resolve their own
  domain's content root - on a multi-domain instance they were rendering
  into the primary's docroot.
- **A backup of a live site no longer fails** because a visitor arrived
  mid-snapshot (SM381).

## Upgrading to 0.10.10 from 0.10.0, 0.10.8 or 0.10.9

The fleet spans **0.10.0** (stable) and the edge line, and every one of them
needs the same operator action after upgrading. It is not delivered by the
package.

### Why an upgrade alone is not enough

From 0.10.8, protecting content **moves it out of the document root** into a
private store beside it, so that a front end which serves files without asking
the engine cannot reach protected bytes. That was the structural answer to
SM248, SM268 H17 and SM283.

The move happens **on the act of protecting**. It is not a migration, and no
upgrade performs it retrospectively. So:

```datatable
columns: If the site is on | Then after upgrading to 0.10.10
widths: 3.4cm | X
bold: 1
tone: medium
text: 2
---
0.10.0 (stable) | Every section ever protected still has its FILES in the document root. The rule is stored and honoured for pages; the files are reachable by anyone who knows the path on a front end that answers statics itself. Measured on a real upgraded site: 19 of 25 extensions still served byte-identically to an anonymous request.
0.10.8 (edge) | The same, for anything protected before 0.10.8 - AND anything protected ON 0.10.8 may be in that state too, because SM296 could crash the move after the rule was saved, leaving the content stored-as-protected and still served with no audit line.
0.10.9 (edge) | The same, if the sweep was run and reported success while moving nothing. Until 0.10.10 a re-apply that stored the rule and moved no files counted as "re-applied" and exited 0, so a fleet sweep could report every site done having achieved nothing. **Run it again on 0.10.10 and read the new count.**
```

Both are repaired by the same action, because both are "the rule is right and
the bytes are in the wrong place".

### What 0.10.10 changes about this

Three things, all of which make the SAME action more likely to actually work:

- **The store gets created.** The sweep needs the private store, which is a
  SIBLING of the document root - so repairing the docroot never reached it, and
  a site with a perfectly repaired `public_html` could still move nothing.
  `lazysite check --fix`, run as root, now creates it. See below.
- **A sweep that moves nothing says so.** It is counted as `moved nothing`
  rather than `re-applied`, the cause is named once, and the command exits
  non-zero. On 0.10.9 and earlier it reported success.
- **The rollout checks from OUTSIDE afterwards.** Every run now probes each site
  anonymously and reports whether the front end honoured the rule, because the
  engine's report and the front end's behaviour are different claims and have
  disagreed three times. A site it could not measure is reported as `not
  confirmed` rather than as passing.

### The action

**Re-apply every stored rule.** This re-issues each rule with the values already
in the store - it grants nothing, revokes nothing, and changes no rule. What
changes is where the files live.

Per site:

```bash
# see what would happen (dry run - this is the default)
lazysite acl reapply --docroot /path/to/public_html --actor local

# do it
lazysite acl reapply --docroot /path/to/public_html --actor local --apply
```

Across a Hestia fleet, as part of the rollout:

```bash
bash /tmp/lazysite-0.10.10/installers/hestia/lazysite-hestia-update-all.sh \
     --reapply-acls
```

The sweep runs only on sites that actually upgraded - a site skipped by its
update channel is still on its old version - and runs as each site's own user,
never as root.

`--reapply-acls-dry-run` (SM1238) runs the dry run on the same sites, as the same
users, and moves nothing. Each `NOT MOVED: <path>` line it prints - a rule stored
with its files still in the document root - is reported as a finding, and the
rollout exits 2 if there is one.

::: widebox
**Order matters: upgrade first, then sweep.** The re-apply is the operation
SM296 broke. On 0.10.8 it is the thing that crashes, so running it before the
upgrade repairs nothing and reports failures. `--reapply-acls` sweeps after the
deploy step for exactly this reason.
:::

### The sweep needs the private store to exist

The store is `<docroot>-lazysite-private` - a **sibling** of the document root,
not a directory inside it. Creating it needs write access on the docroot's
*parent*, which on the Hestia layout is the domain folder.

**Repairing the document root does not fix this.** They are different
directories, and a site can have a perfectly repaired `public_html` where the
sweep still moves nothing. That happened on a live instance in August 2026:
`MKCOL`, `PUT`, overwrite and `DELETE` at the site root all worked, and
protecting a folder still left every file public and anonymously reachable.

```bash
lazysite check --docroot /path/to/public_html          # names the store, owner, mode
sudo lazysite check --docroot /path/to/public_html --fix   # creates it
```

`--fix` creates the store owned by the site user, mode 2770. It deliberately
does **not** make the parent directory group-writable: that parent also holds
`cgi-bin`, and write permission on a directory is permission to rename its
entries, so the wider repair would open a larger hole than the one being closed.

From 0.10.10 the sweep reports this rather than hiding it. A re-apply that stores
the rule and moves nothing counts as `moved nothing`, not as `re-applied`, and
the command exits non-zero - so a fleet sweep that achieved nothing can no longer
report success.

### Verify from outside

Do not take the sweep's own word for it. The engine's report and the front end's
behaviour are different claims, and SM283 was the case where they disagreed.

**From 0.10.10 the fleet rollout does this for you**, per site, at the end of
every run - reporting `verified`, `exposed` and `not confirmed` separately, and
exiting non-zero on an exposure. Run it by hand for a single site, or to re-check
after repairing one:

```bash
lazysite check --check-acl https://<domain>/
```

That gates a probe folder against a principal which cannot exist and fetches it
anonymously under several extensions, with a public control of the same type
alongside each - so a refusal that happens because the front end cannot read the
file is distinguishable from a refusal that is the access rule working.

### Also outstanding from 0.10.7, on Hestia

SM283's remedy is an nginx **proxy template**, and it is likewise not delivered
by a package upgrade: the template must be staged and each domain moved onto it.

```bash
bash /tmp/lazysite-0.10.10/installers/hestia/lazysite-hestia-update-all.sh \
     --proxy --reapply-acls
```

Check whether a domain has it with no credentials:

```bash
curl -sI https://<domain>/ | grep -i X-Lazysite-Front
```

A domain with an ACL store and no `X-Lazysite-Front` header is on a stock proxy
and is the SM283 shape. `lazysite-hestia-list.sh` flags those as
`ACL-BYPASSED-BY-PROXY(SM283)`.

### Optional, and separate

`lazysite migrate-engine-tree --apply` moves the `lazysite/` engine tree out of
the document root (SM293). Dry-run by default, reversible with `--back`, and
gated by `--min-version`. It is unrelated to the re-apply sweep and can be done
whenever.

## manager_groups retired (SM138)

The legacy `manager_groups:` key in `lazysite.conf` is retired. Manager access
is granted by **groups**: any group carrying the `ui` capability (manager UI) or
`manage_users` (operator powers), managed on the manager **Groups** page.

**Migration is automatic.** On the first settings read after upgrade, any group
the conf key named receives the full manager grant explicitly (every capability
except the remote `api`/`mcp` channels - manager groups are interactive-only),
and the `manager_groups:` line is removed from `lazysite.conf`. Effective access
is unchanged: those groups had unrestricted operator access through the fallback
already. No operator action is needed; a lingering line (e.g. an unwritable
conf) is simply ignored.

If **no** group grants manager access at all, the site is in the unsecured/dev
mode where any authenticated user is a manager - run
`lazysite-users.pl setup-sysop` (or grant `ui` to a group) to secure it, as
before.

## WebDAV publishing (SM070)

A WebDAV endpoint (`/dav`) is available for headless, per-file
content publishing. It is **off by default** — an existing install is
unchanged after upgrade until you opt in. To enable it:

1. Add `webdav_enabled: true` to `lazysite/lazysite.conf`.
2. Add the `/dav` ScriptAlias to your web server. The shipped Hestia
   templates include it; for a hand-rolled Apache vhost add
   `ScriptAlias /dav /path/to/cgi-bin/lazysite-dav.pl` and ensure the
   `RequestHeader unset X-Remote-*` lines are present (now in the
   shipped templates).
3. For each publishing account, set `webdav on` (and usually a
   `dav_scope`) on the manager Users page, then generate a credential.

The Hestia templates also gained the `RequestHeader unset X-Remote-*`
directives that `docs/architecture/security.md` has always required;
they need Apache's `mod_headers`. See
`docs/features/configuration/webdav.md` for the full guide.

## 0.2.x to 0.3.0

The installer is now upgrade-aware. This is the first version
with safe in-place upgrades: a later release can be applied to a
site without losing its content. (0.3.0 reached that by re-running
`install.sh`; today it is `lazysite upgrade` - see *How to upgrade*
at the top.)

### What this enables

- Seed files you have edited (starter pages, your custom docs,
  registry templates) are preserved across upgrades.
- Code files (processor, plugins, manager UI, system theme)
  are overwritten with each new release.
- Files removed in new versions are cleaned up only if you
  haven't edited them; edited orphans stay and produce a
  warning.
- Pre-upgrade backups accumulate under
  `{docroot}/lazysite/backups/`, retained per
  `backup_retention` in `lazysite.conf` (default 3; 0 = keep
  all).
- `--dry-run` shows the full upgrade plan without modifying
  anything.

### What does NOT get migrated

Installs created with 0.1.x or 0.2.x pre-dating the 0.3.0
installer do not have `.install-state.json`. The installer
treats them as fresh installs: it walks the manifest and
skips-if-present, which is the old behaviour. The first
post-0.3.0 run establishes `.install-state.json` for future
upgrades. Effectively, 0.3.0 is where upgrade-tracking begins.
Plan to back up your docroot before the first 0.3.0 install
on an existing deployment.

### If upgrade goes wrong

Every upgrade creates a backup first. To list them:

```bash
lazysite backups --docroot /path/to/public_html
```

To restore the most recent, or a specific one:

```bash
lazysite backups --docroot /path/to/public_html --restore
lazysite backups --docroot /path/to/public_html --restore --backup PATH
```

Restore does not touch runtime state (auth users, cache,
logs). It invalidates the rendered HTML cache afterwards so
stale pages don't linger.

### No default layout or theme ships

0.3.0 ships no layout or theme content of its own. A fresh
install has no `lazysite/layouts/NAME/layout.tt`, and the
processor falls back to a built-in template until one is
installed. Install a layout + theme via the manager UI at
`/manager/themes` > "Install from Releases" (the configured
`layouts_repo` default is `OpenDigitalCC/lazysite-layouts`),
or drop a layout directory in manually.

### New files installed

`install.sh` now installs:

- `install.pl` at the repo root (the real installer; the
  shell script is a thin wrapper).

### No change for fresh installs

First-time installs work the same as before.
`.install-state.json` is created automatically on first run.

## 0.1.0 to 0.2.0

Breaking changes in this release. Read the whole file before
upgrading a production install.

### Plugin URLs changed

Plugins moved from `/cgi-bin/lazysite-*.pl` to `/cgi-bin/*.pl`:

- `/cgi-bin/lazysite-form-handler.pl` -> `/cgi-bin/form-handler.pl`
- `/cgi-bin/lazysite-payment-demo.pl` -> `/cgi-bin/payment-demo.pl`

Update any external integrations pointing at these URLs:

- Web form `action=` attributes in custom pages
- Webhook URLs in `handlers.conf`
- External systems POSTing to `form-handler`
- Payment flow URLs

`form-smtp` is not a URL endpoint (it runs as a subprocess of
`form-handler`), so nothing to update there.

### Plugin source locations changed

Plugin scripts moved from the repo root (and `tools/`) to
`plugins/`, dropping the `lazysite-` prefix:

- `lazysite-form-handler.pl`   -> `plugins/form-handler.pl`
- `lazysite-form-smtp.pl`      -> `plugins/form-smtp.pl`
- `lazysite-payment-demo.pl`   -> `plugins/payment-demo.pl`
- `lazysite-log.pl`            -> `plugins/log.pl`
- `tools/lazysite-audit.pl`    -> `plugins/audit.pl`

Core scripts keep their `lazysite-` prefix at repo root:

- `lazysite-processor.pl`
- `lazysite-auth.pl`
- `lazysite-manager-api.pl`

`install.sh` now places plugins under `{docroot}/../plugins/`
and symlinks `form-handler.pl` and `payment-demo.pl` into
`cgi-bin/` for Apache routing. The dev server
(`tools/lazysite-server.pl`) discovers both locations.

### Plugin enable-list entries become stale

Your installed `lazysite.conf` has `plugins:` entries referencing
the old plugin paths, for example:

    plugins:
      - cgi-bin/lazysite-form-handler.pl
      - tools/lazysite-audit.pl

After upgrading to 0.2.0, these paths no longer resolve. The
manager UI will treat the plugins as disabled, even though the
underlying scripts are installed. Form processing, audit runs, and
any other affected features stop working silently.

**To fix:**

**Option 1 - via the manager UI.** Visit `/manager/plugins` and
toggle each plugin off then on. The new paths are written to
`lazysite.conf` in the new format.

**Option 2 - hand-edit lazysite.conf.** Replace old paths with
new ones:

    cgi-bin/lazysite-form-handler.pl  -> plugins/form-handler.pl
    cgi-bin/lazysite-form-smtp.pl     -> plugins/form-smtp.pl
    tools/lazysite-audit.pl           -> plugins/audit.pl
    lazysite-log.pl                   -> plugins/log.pl

Leave `lazysite-auth.pl` alone - it stays at repo root and keeps
its old entry.

This migration will be automatic in 0.3.0 when the upgrade-safe
installer lands (D021c).

### Upgrade procedure

1. Review external integrations (webhooks, custom form actions,
   payment flows). Update any URLs that point at the old
   `/cgi-bin/lazysite-*.pl` paths.
2. Take a backup of your site. (The upgrade-safe installer arrives
   in 0.3.0; for now, backup is manual.)
3. Extract `lazysite-0.2.0.tar.gz` and apply it to the same
   `--docroot` and `--cgibin` you used for 0.1.0. (0.2.0 was
   installed by re-running `install.sh`; today that is
   `lazysite upgrade` - see *How to upgrade* at the top.)
4. The installer places new plugins under
   `{docroot}/../plugins/`. Old plugin files left over from 0.1.0
   in `/cgi-bin/` or `{docroot}/../` can be removed manually once
   you have confirmed the new layout works.
5. Reconcile `lazysite.conf` `plugins:` entries per the previous
   section.
6. Restart Apache (or reload the config) to ensure routing
   changes take effect.

### New files installed

`install.sh` now catches up with files that were in the release
manifest but previously not installed by the installer:

- `starter/lazysite/templates/docs/features/` subtree (authoring, configuration, and
  development feature docs) under `{docroot}/docs/features/`
- `tools/lazysite-server.pl` (dev/evaluation server) and
  `tools/build-static.sh` (static site export) under
  `{docroot}/../tools/`
- `lazysite.conf.example` and `nav.conf.example` as reference
  files under `{docroot}/lazysite/`
- `users.example` and `groups.example` under
  `{docroot}/lazysite/auth/` as references, and as seed sources
  for `users` / `groups` on fresh installs
