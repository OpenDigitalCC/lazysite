---
title: "SM365 - a layout update leaves the site on the old theme"
subtitle: "The template updates, the stylesheet does not, and `themes_installed` names a real theme truthfully. The new theme installs beside the one in use, under a dated name nothing points at."
brand: plain
status: shipped
status-note: "SHIPPED 2026-08-17, filed and fixed the same day from the layouts agent's and the site agent's measurements on edge. The mechanism is an ASYMMETRY rather than a missing call: _install_layout_from_dir has always taken an update flag and written in place, and _install_theme_from_dir had none at all - so on an update the theme hit the collision branch and installed as 20260817-<name>, the mirror ran for THAT, and the site went on serving the old one. Fixed by threading the update flag through and snapshotting before overwrite, so the protection the rename provided (an operator's edited theme is not clobbered by a same-named arrival) is kept rather than traded away. _snapshot_artifact is already a no-op on a theme still at its pristine baseline (SM176), so an unedited theme costs nothing. Reproduced as a failing test before the fix."
---

# What was measured

After `lumen` was upgraded to catalogue 1.1.0 on edge (engine 0.10.12):

```datatable
columns: What | State after the upgrade
widths: 6.4cm | X
bold: 1
tone: medium
---
`/lazysite/layouts/lumen/layout.tt` | the NEW template - 1.1.0 head contract, nav markup, toggle with aria attributes, wiring script correctly placed
`/lazysite-assets/lumen/lumen/main.css` | the PRE-upgrade stylesheet, byte-identical to a copy captured that morning, carrying 0 `.nav-toggle` rules where the repo CSS has 2
`/lazysite-assets/lumen/lumen/favicon.svg` | 404, while the release pack ships `assets/favicon.svg`
---
```

Below 900px the stale CSS hid the navigation with no rule to reveal the toggle,
and the declared favicon 404'd. Both present as catalogue bugs and are not - the
packs verify correct. A **fresh** install delivers the right files; only an
update does this.

# The mechanism

```perl
my $install_name = $theme_name;
if ( -d $first_dest ) {
    $install_name = sprintf( "%04d%02d%02d-%s", ..., $theme_name );
}
```

An existing theme was read as a **collision**. So the update installed
`20260817-lumen`, the asset mirror ran for `20260817-lumen`, and `lumen` - the
name the site's config points at - was never touched.

Every surface then reported success, correctly: a theme was installed, and
`themes_installed` named it. The report was true of the engine and false about
the world.

That is the shape of SM283, SM296, SM306, SM311, SM313, SM315, SM317, SM322,
SM329, SM337, SM340, SM344 and SM356. [[SM315]] is the closest relative - a
mirror path whose result was discarded - and this arrives through upgrade rather
than activation, so it is a different path with the same hole.

# Why the rename is kept

A theme arriving with a name an operator already uses must not clobber their
work, and stepping aside under a dated name is a reasonable answer to that. What
was wrong is that an **explicit update** was being treated as that case.

So the branch stays and gains a condition. An update replaces the theme in use,
after snapshotting it; anything else still steps aside.

# Edge is correct by hand, not by upgrade

The site agent has run the re-mirror remedy on edge: `lumen`'s live `main.css`
now matches the release pack exactly and `favicon.svg` serves 200.

**So edge's correctness is not evidence that this fix works.** The fix means the
NEXT update refreshes the theme in use; it does not repair what a previous
update left beside it. The field test is the next real layout upgrade, and until
then the instance proves only that the manual remedy works.

Recorded because an instance that looks right is the easiest thing in the world
to read as a fix confirmed - which is the same mistake, in the same release, as
reading `themes_installed` as a theme installed where it was needed.

# Verification

- A layout update replaces the theme the site is using, and the mirrored
  stylesheet is the new one.
- After an update there is one theme directory, not a dated sibling beside it.
- A same-named theme that is NOT an update still installs under a dated name and
  leaves the theme in use untouched.
- An operator who had edited the theme can still recover it from a snapshot.

# Related

[[SM315]] (a mirror whose result was discarded), [[SM176]] (the pristine
baseline, which is why snapshotting an unedited theme costs nothing), [[SM123]]
(theme discovery and the asset-mirror lifecycle), and
`inbox/archive/2026-08-17-layout-upgrade-does-not-remirror-theme-assets.md`.
