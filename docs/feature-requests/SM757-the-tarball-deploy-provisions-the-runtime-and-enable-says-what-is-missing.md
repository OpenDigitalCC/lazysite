---
id: SM757
title: "SM757: the tarball deploy provisions the runtime, a timer starts it, and Enable says what is missing"
subtitle: "The release manager, 2026-09-06: the edge host is a tarball install and will not take the debs; the installer runs as root and should do all of it; on upgrade it must be automatic; pressing Enable should check and advise. The daemon's unit had only ever shipped in the deb, and its unit could not be started by a sysop - the manager has no root."
brand: plain
standard-margins: true
status: shipped
status-note: "BUILT 2026-09-06 on claude/sm757-the-tarball-deploy-provisions-the-runtime for 0.13.2. (1) The unit moves into the tarball (installers/systemd/lazysited@.service, the deb installs it from there) and takes its engine from ENGINE= with a default of /usr/share/lazysite; lazysite-hestia-deploy.sh (root, the tarball flow's per-site deploy, run by lazysite-hestia-update-all.sh on every deploy and upgrade) writes /etc/lazysite/daemon/<domain>.conf with ENGINE=<domain root>, installs the unit and its timer into /etc/systemd/system when they changed, daemon-reloads, enables the timer, and restarts a running runtime. Nothing by hand; nothing into the site tree. (2) lazysited@.timer: while the service is not running it is started every five minutes, so a sysop enabling the plugin - no root - is picked up within five minutes; the deb tool enables the timer on add --daemon and disables it on remove. (3) Enable runs the Status action (on_enable), which now checks the host conf naming this docroot, the timer, the service, the job account and each job's capability, and shows one sentence beside the toggle naming what is missing. Also, from the field pass: WebDAV's not-found refusals carry a detail line. The deploy watcher and update-all are unchanged. t/tools/68, t/unit/daemon/08, t/tools/66 and 67 updated."
---

# The ruling

> I won't install debs on this host, it risks disrupting the sites. so testing
> requires the tar. the installer runs as root and uses sudo so it should be able
> to do this all. on upgrade, make sure it is automatic. when plugin enable
> pressed, this should be checked and operator advised if there are any problems.

# What was true

The daemon's unit lived in `debian/` and its `ExecStart` named
`/usr/share/lazysite`, which a tarball host does not have; `^debian/` is
excluded from the tarball. The pool has the same shape and has only ever been a
deb feature - the runbook marks the tarball scripts superseded. So on the edge
host, which is a tarball install and will stay one, 131E-01 could only ever be
"not provisioned".

And the two-switch design had a gap the 0.13.1 review recorded in passing: the
unit is `Restart=on-failure` (a disabled runtime exits 0, and `always` would
hot-loop hundreds of disabled sites), so once it had exited, a sysop enabling
the plugin in the manager - which has no root - could not start it. The Status
remedy told them to run `systemctl`, which they cannot.

# What changed

**One unit for both flows.** `installers/systemd/lazysited@.service` ships in
the tarball; the deb installs the same file. `Environment=ENGINE=/usr/share/lazysite`
is the deb's default; `EnvironmentFile=` overrides it, so a tarball host's conf
carries `ENGINE=<domain root>` and the runtime runs the site's own `tools/` and
`lib/`.

**The deploy provisions, every time.** `lazysite-hestia-deploy.sh` - root, run
per site by `lazysite-hestia-update-all.sh`, which the deploy watcher runs -
writes the conf, installs the unit and timer when they differ from the release,
`daemon-reload`s when they changed, enables the timer, and restarts a running
runtime so an upgrade takes effect the way a pool restart does. Guarded on a
running systemd; nothing written into the site tree. **The watcher
(`tools/lazysite-deploy.sh`) and `update-all` are unchanged** - the change is
where root already was.

**A timer starts the service.** `lazysited@.timer`: `OnUnitInactiveSec=300`.
While the service is not running it is started every five minutes; it reads the
plugin and either runs or exits in well under a second. A sysop's Enable is
therefore picked up within five minutes, at one short-lived process per five
minutes per disabled site, and nothing while one runs. The deb tool enables the
timer on `add --daemon` and disables it first on `remove`.

**Enable checks and advises.** `plugins/daemon.pl` declares `on_enable =>
'status'` (the SM085 hook), so the toggle runs the same Status the button runs.
`Supervisor::status` now reads the host - which conf under
`/etc/lazysite/daemon/` names this docroot (by `DOCROOT=`, resolved), whether
its timer is enabled and its service active (`systemctl is-enabled` /
`is-active`, which answer anyone) - and the job account the way the scheduler
will, plus each job's capability; the result carries `host`, `checks` and one
`summary` sentence, which the Plugin Manager shows beside the toggle. The
remedies: provisioned and timer enabled - "starts within five minutes";
provisioned, timer off - the exact `systemctl enable --now lazysited@<i>.timer`;
not provisioned - "the Hestia deploy does it, or `lazysite-hestia-domain add
… --daemon`"; job account absent or short of a capability - which one.

# What is held

`t/tools/68` - the deploy writes exactly the keys the unit reads, installs both
units from the stage into `/etc/systemd/system`, reloads only on change,
enables the timer and not the service, restarts only a running runtime, writes
nothing into the site tree. `t/unit/daemon/08` - the host probe finds a conf by
`DOCROOT` not by name; each of the three host states yields its remedy; the job
checks name the job that will be refused and the grant; the summary carries it;
the plugin runs Status on Enable and the page shows it. `t/tools/66`, `67` and
`t/unit/daemon/03` follow the unit to its new home.

# Related

SM666 (the runtime), SM222 (`starting` is the timer's word too),
`docs/review/0.13.1-daemon/` F5.8 (never run on a real host - this is what
makes that possible on the host we have), SM750 (the WebDAV not-found detail).
