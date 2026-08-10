---
title: "SM270 - A vhost rebuild undoes the permission repair, and 0.10.5 tells every operator to rebuild"
subtitle: "Hestia resets the docroot to its own default on rebuild. The deploy script repairs that - but it runs BEFORE the rebuild, so following the 0.10.5 upgrade instructions leaves the docroot unwritable."
brand: plain
status: candidate
status-note: "FILED 2026-08-10 from a live 0.10.5 upgrade: the operator refreshed the Hestia template, rebuilt the vhost to pick up the SM268 H17 PT fix, and public_html came back drwxr-s--x (2751, no group write). Repaired by hand. This is the 0.6.5 incident class - the one SM246 exists for - reached by a route nothing checks. The 0.10.5 release notes and debian/changelog both say 'existing vhosts must be re-rendered' and NEITHER warns that re-rendering resets permissions."
---

# SM270 - a vhost rebuild undoes the permission repair

## What happened

A live 0.10.5 upgrade. The operator refreshed the Hestia web template,
ran `v-rebuild-web-domain` to pick up the SM268 H17 `PT` fix, and found:

```
drwxr-s--x 11 ispadmin www-data 4.0K Aug 10 16:14 public_html
```

`2751`. Setgid, and **no group write** - so the CGI (`www-data`) cannot
write the docroot, which is every authoring surface the product has. They
repaired it by hand.

## Why

Three facts that are individually reasonable and collectively a trap.

**Hestia resets the docroot on rebuild.** `v-rebuild-web-domain`
re-applies its own ownership and permission defaults. That is Hestia
behaving normally.

**lazysite knows this and repairs it - in the rebuild hook.**
`installers/hestia/lazysite-app.sh` line 25 is `chmod 2775 "$docroot"`,
and it exists for exactly this reason. But the hook Hestia runs is the
copy in `$TPLDIR`, not the one in the tarball, so it only helps if the
template has already been refreshed. An operator who rebuilds before
refreshing runs the old hook.

**The other repair runs at the wrong time.**
`lazysite-hestia-deploy.sh` does a full permission sweep
(`find "$DOC" -type d -exec chmod 2775`), which would fix this - but it
runs during DEPLOY. The documented upgrade sequence is deploy first, then
rebuild the vhost by hand. So the repair happens, and then the rebuild
undoes it.

Nothing checks afterwards. The site is left unwritable and the operator
finds out when the manager fails to save.

## Why this matters more than a one-off

**0.10.5 tells every operator to do this.** The release notes and
`debian/changelog` both lead with "existing vhosts must be re-rendered"
for the H17 fix - and neither warns that re-rendering resets permissions.
Anyone following the upgrade instructions on a Hestia host hits this. It
is not an edge case; it is the documented path.

**It is the incident SM246 was written for**, arriving by a route SM246
does not cover. SM246 made the installer declare and apply directory
modes, and 0.10.5 made `lazysite-check` verify them - but neither runs
after a Hestia rebuild, because the rebuild is an operator action outside
the tooling.

## What to build

**1. Order the operations, and own the rebuild.**
`lazysite-hestia-update-all.sh` should refresh the template, rebuild the
vhost, and THEN deploy - so the permission sweep is the last thing that
touches the tree. Today the rebuild is a manual step the operator performs
after everything else, which is the wrong end.

**2. Verify after, do not assume.** A post-deploy check that the docroot
is group-writable, reported per site in the existing health summary. The
whole shape of this defect is that a repair ran and something later undid
it, which only a check after the fact catches.

**3. Say it in the instructions.** Any release whose notes say "re-render
your vhosts" must also say what a re-render costs and how to repair it.
That is a documentation rule, not a one-off edit - and the 0.10.5 notes
need it retrospectively.

## Not in scope

Changing Hestia's own behaviour, or fighting it. Resetting the docroot on
rebuild is Hestia's prerogative; the fix is for lazysite to run after it
and to stop telling operators to rebuild without saying what follows.

## Related

SM246 (the permission model), SM268 H17 (the `PT` fix that makes the
rebuild necessary), SM215 (`lazysite-check --fix` as the canonical
repairer).
