---
id: SM907
title: "SM907: an unwritable audit trail reads as a site where nothing happened"
subtitle: "On the same new 0.14.4 install, lazysite/logs/audit.log was mode 0664 owned ispadmin:ispadmin, so the www-data CGI could read it and not append to it. The trail showed six events, all of them written by root or the site user from the shell, and none of the web server's - not the agent's deployment, not the operator's own login. The audit page rendered that as a short, healthy list. `lazysite check` found it in one pass once it was run, but nothing had asked it to: the directory tests verify setgid and group-write and never the GROUP, so a logs directory that hands every new file the wrong group passes."
brand: plain
standard-margins: true
status: candidate
status-note: "RAISED 2026-09-27 from the field, cause CONFIRMED on the host by `lazysite check`, and repaired there by `--fix`. The operator asked whether an agent's deployment leaving no trail was a permissions problem. It was, and the decisive evidence was a row of the operator's own: viewing the audit page requires a manager login, a successful login is audited, and there was no login row. The trail was split by WRITER IDENTITY, not by action or surface - every row present came from a root or site-user process, every row absent would have been written by the web server. Nothing to do with the agent's capabilities: every state-changing MCP tool and control-API action audits after the capability gate, and a refusal audits too, so a denied agent leaves rows saying so. AT2 SHIPPED 2026-09-27 for 0.15.0: six trail states named, the sentence composed once on the server, an unopenable trail refused rather than answered empty, `lazysite/logs` reclassified as a store so lint 121 holds it, and t/unit/manager/196 asserting the six differ. AT6 was raised by that work, for the visitor log in the same directory. Five rows proposed. AT1 and AT3 were then asked for and are WITHDRAWN 2026-09-27, both premises measured false: the check already compares a declared directory's group (496-508, and t/tools/04-check.t passes --group for that reason), and a fresh install leaves audit.log correct because it inherits the group from its setgid directory - the installer's pass only chmods, so covering it would change nothing. The auth stores, created later still by setup-sysop, arrive 0660 under umask 022 and 027 alike. So the engine builds a correct tree and the check detects the broken one; AT2 is the only row left that is a defect, and what changed that file's group on the host is not something this agent can name from here."
raised: 2026-09-27
raised-by: release manager (the oca-odoo.com 0.14.4 install)
area: diagnostics, audit
---

# What was reported

An AI agent deployed a site. Nothing appeared in the audit trail. The setup
commands were all there. The operator asked whether it was a permissions
problem.

The trail held six events: `installed 0.14.4`, two `setup-sysop`, two
`user-claim-create`, and one `user-account-create`. Every one of them `system`
or `system:ispadmin`, source `install` or `cli`.

# What was measured

`lazysite check` on the host, before anything was changed:

```
[ FAIL ] lazysite/logs/audit.log (0664, ispadmin:ispadmin) is not writable by
         the CGI (www-data) - the manager cannot save it
[  ok  ] lazysite/logs writable + setgid (2775)
```

The mode was never the problem. The GROUP was. At 0664 with group `ispadmin`,
the www-data CGI holds only the world bits: it can read the file, which is why
the audit page rendered, and it cannot append to it, which is why nothing the
web server wrote ever arrived.

`--fix` repaired it and the tree came back 45 ok, 0 failures. The operator
confirms the trail records again.

# The evidence that settles it, before any check was run

Not the agent's missing rows. A row of the operator's own.

Viewing the audit page needs a manager session, and every login is audited -
`login`, status ok, origin `ui`, at `lazysite-auth.pl:311`. There was no login
row. Nor a `claim-redeem` row, though two claim links had been issued.

So the split in the trail is not by action, and not by surface. It is by WRITER
IDENTITY. Everything present was written by a process running as root or as the
site user. Everything absent would have been written by the web server. That
shape has one cause and it is not a capability.

# What it is NOT

**Not the agent's grants.** Every state-changing MCP tool audits at
`lazysite-mcp.pl:3713`, after the channel and capability gates, and a REFUSAL
audits too with status `fail` and the cause in the detail field. A denied agent
leaves rows saying it was denied. Silence means the lines never reached the
file.

**Not the audit-trail switch.** `audit_trail: off` would have stopped the CLI
rows as well, and they are present.

**Not a path divergence.** The reader and the CGI writer derive the same engine
directory, so a page that shows the CLI's rows is reading the file the CGI
writes.

**Not a packaging gap.** This agent claimed during the diagnosis that the
tarball shipped no `tools/` directory and therefore no check. That was wrong,
measured from a truncated listing: the 0.14.4 tarball carries 136 entries under
`tools/`, `lazysite-check.pl` and `lazysite-cli.pl` among them. Recorded here
because a withdrawn finding that is not written down gets re-found.

# Why the check did not catch it before the trail lost anything

It was never asked to run. That is the whole of it, and the first version of this
filing said more than that and was wrong.

# What building AT1 and AT3 found, 27 September

Both were claimed here as defects. Both premises measure FALSE. Recorded at
length because a disproved row that is quietly dropped gets re-filed by the next
reader of the first draft.

**AT1 is wrong: the check DOES compare a declared directory's group.** This
filing claimed the directory tests verify mode only. They are two loops, not one.
The mode tests are at `tools/lazysite-check.pl:340-361`, and section 3 at
`496-508` walks the SAME `%want_dir` set comparing each directory's group to the
expected CGI group, failing with the recursive chown. `t/tools/04-check.t:59`
passes `--group` for exactly that reason, in those words: "otherwise the group
check would (correctly) flag them".

Measured, not read. One scratch docroot, `lazysite/logs` at 2775, the check run
twice over it changing only the EXPECTED group:

```
logs/ group = claude; measuring with expected group = users
expected=claude   group findings: NONE
expected=users    group findings:
  [ FAIL ] lazysite/auth group is claude, expected users ...
  [ FAIL ] lazysite/cache group is claude, expected users ...
  [ FAIL ] lazysite/logs group is claude, expected users ...
```

The claim came from reading one loop and not the one twenty lines below it - the
same mistake as the tarball claim above, made twice in one diagnosis.

It also follows that `lazysite/logs` DID carry the CGI group on the host, because
that pre-fix run reported no group failure. So the directory was right and the
file in it was wrong, which means nothing inherited the wrong group: something
set it, after the file was created.

**AT3 is true as an ordering fact and buys nothing.** The pass at
`install.pl:1651` does skip files that do not exist (`next unless -f $p`), and the
installer does write its first audit line later at `install.pl:825`, so the audit
log is genuinely the one declared runtime file the pass never covers. But the pass
only chmods - `chmod( $m | 0020, $p )` - so covering it could not have changed
anything, and a real fresh install leaves the file correct anyway. Measured, with
the docroot given a group that is NOT the installing user's primary group, so an
inherited group and a creator's group are distinguishable:

```
primary group=claude  docroot group=users
lazysite/lazysite.conf              0664   users   inherited the docroot group
lazysite/logs                       2775   users   inherited the docroot group
lazysite/logs/audit.log             0664   users   inherited the docroot group
```

**The nearest alternative is false too.** That measurement showed the auth stores
absent after a provision: `users`, `groups`, `groups-settings.json` and
`user-settings.json` are created later by `setup-sysop` from a shell, so the pass
cannot cover them either and their modes come from the operator's umask. Under
umask 022 and again under 027, every one of them arrives 0660 and group-writable.
The writers are already umask-proof, as `Lazysite::Audit` is for the log.

So the engine produces a correct tree on a fresh install, and the check detects
the broken state in one pass. Neither AT1 nor AT3 is a defect, and neither is
built. What changed that file's group on the host was something after the
install, and this agent cannot name it from here - it is not the installer, and
it is not a umask.

# What the page should have said

Nothing told the operator. The append fails, `Lazysite::Audit::_warn_once` warns
once per process, and `log_event` prints to standard error, which for a CGI means
the web server's error log. The audit page itself renders six events and looks
healthy.

That is the four-state boolean again, and the third time this line has been
crossed this month: SM873 for a store that cannot be inspected, SM906 for an auth
store that cannot be read, and now a trail that cannot be appended to. An empty
list must not be the answer to "what happened here" when the real answer is "this
site cannot tell you".

# The work

| Ref | Complexity | What |
|-----|-----------|------|
| AT1 | - | WITHDRAWN 2026-09-27, premise measured false. The check already compares a declared directory's group, at `tools/lazysite-check.pl:496-508`, and fails with the recursive chown. Nothing to build. |
| AT2 | S | SHIPPED 2026-09-27 for 0.15.0. The audit action answers which of six states the trail is in, with the file and the repair, and the page shows it above the table and before the empty-list shortcut. A trail that exists and will not open is a refusal (`store-uninspectable`, 500) rather than `ok` with nothing in it. `lazysite/logs` is a store in `Lazysite::Stores` now, so lint 121 holds the rule. `t/unit/manager/196` covers all six and asserts they differ. |
| AT3 | - | WITHDRAWN 2026-09-27, premise measured false in effect. The ordering is real - the audit log is created after the pass - but the pass only chmods and a fresh install leaves the file correct, group inherited from its setgid directory. Covering it changes nothing. Nothing to build. |
| AT4 | XS | The check's CGI-writable message names the right consequence per file. For the audit log it says "the manager cannot save it"; it is appended by every surface, and entries are lost without trace. |
| AT6 | M | RAISED by AT2, from the catalogue entry it rewrote. `lazysite/logs` is a store now, and the VISITOR log in it has the same property: `plugins/stats.pl` holds six read-opens that answer empty, so an unreadable visitor log reads as a site nobody visited. Not covered by lint 121 yet, because only the audit reader is listed as a module - named here rather than silently excluded. |
| AT5 | XS | `starter/lazysite/forms/smtp.conf.example` ships world-readable, so an operator copying it into place produces a world-readable credentials file - which is the second failure this host reported. The manager's own save chmods 0660, because the extension declares a `password` field; the example should start where the save would leave it. |

AT2 is the only row left that is a defect. The detection already exists and the
install is already correct, so the single thing this incident proves the engine
lacks is a site that SAYS its trail cannot be written, rather than showing a short
list and looking well.

# What this cost

One site's audit trail recorded nothing from the web server between 17:25 and
the repair. Every manager login, every agent write, and the deployment the
operator asked about are not in it and cannot be recovered. The trail is the
record a sysop is meant to be able to trust, so the gap matters more than the
hour it covers.
