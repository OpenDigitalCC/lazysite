---
id: SM907
title: "SM907: an unwritable audit trail reads as a site where nothing happened"
subtitle: "On the same new 0.14.4 install, lazysite/logs/audit.log was mode 0664 owned ispadmin:ispadmin, so the www-data CGI could read it and not append to it. The trail showed six events, all of them written by root or the site user from the shell, and none of the web server's - not the agent's deployment, not the operator's own login. The audit page rendered that as a short, healthy list. `lazysite check` found it in one pass once it was run, but nothing had asked it to: the directory tests verify setgid and group-write and never the GROUP, so a logs directory that hands every new file the wrong group passes."
brand: plain
standard-margins: true
status: candidate
status-note: "RAISED 2026-09-27 from the field, cause CONFIRMED on the host by `lazysite check`, and repaired there by `--fix`. The operator asked whether an agent's deployment leaving no trail was a permissions problem. It was, and the decisive evidence was a row of the operator's own: viewing the audit page requires a manager login, a successful login is audited, and there was no login row. The trail was split by WRITER IDENTITY, not by action or surface - every row present came from a root or site-user process, every row absent would have been written by the web server. Nothing to do with the agent's capabilities: every state-changing MCP tool and control-API action audits after the capability gate, and a refusal audits too, so a denied agent leaves rows saying so. Four fixes proposed, none built yet."
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

It was never asked to run. But it also could not have been failed by the state
that caused this, short of the one file that happened to expose it.

The directory tests at `tools/lazysite-check.pl:340-361` verify MODE only: the
group-write bit and setgid. They never compare the directory's group to the
expected CGI group. So `lazysite/logs` reported ok at 2775 while its group was
`ispadmin`, and every file created in it inherited `ispadmin` through the setgid
bit that the check had just confirmed was set.

The failure message in that same loop says `no setgid (new files miss the
group)`. The mechanism is understood. The group being inherited is not checked.

# Why the audit log was the only file that showed it

Because it is the only declared runtime file created AFTER the installer's
permission pass.

That pass is at `install.pl:1651`. It walks `runtime_files` from
`classification.json` and skips anything that does not exist yet
(`next unless -f $p`). The installer writes its own first audit line later, at
`install.pl:825`. So on every fresh install the audit log is created after the
pass that would have covered it.

And the pass only ever chmods - `chmod( $m | 0020, $p )` - never chowns. Even
had the file existed, a pass that adds a group-write bit already present would
have changed nothing. The ownership of that file rests entirely on the group its
directory carries at the moment it is created.

Every other declared file was written by the installer, covered by the pass, and
passed the check.

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
| AT1 | S | The declared-directory tests compare the GROUP to the expected CGI group, not only the mode, and fail with the chown remedy. This alone catches the host at install, before the trail loses anything. |
| AT2 | S | The audit page reports that the trail cannot be written, as a refusal state with the file, the fault class and the repair - not a shorter list. Covers the absent file too: missing and unreadable are different answers. |
| AT3 | S | The installer covers the audit log: create it before the declared-file pass, and let that pass correct ownership as well as the mode, so the one file that arrives late is not the one file the model never reaches. |
| AT4 | XS | The check's CGI-writable message names the right consequence per file. For the audit log it says "the manager cannot save it"; it is appended by every surface, and entries are lost without trace. |
| AT5 | XS | `starter/lazysite/forms/smtp.conf.example` ships world-readable, so an operator copying it into place produces a world-readable credentials file - which is the second failure this host reported. The manager's own save chmods 0660, because the extension declares a `password` field; the example should start where the save would leave it. |

AT1 and AT3 are the pair that matter. AT1 is the detection the operator would
have had, AT3 is the install that would not have needed it.

# What this cost

One site's audit trail recorded nothing from the web server between 17:25 and
the repair. Every manager login, every agent write, and the deployment the
operator asked about are not in it and cannot be recovered. The trail is the
record a sysop is meant to be able to trust, so the gap matters more than the
hour it covers.
