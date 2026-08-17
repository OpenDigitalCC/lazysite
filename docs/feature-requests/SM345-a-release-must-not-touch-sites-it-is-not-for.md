---
title: "SM345 - a release touched every site on the host, not the ones it was for"
subtitle: "The per-site install was channel-gated. Every other phase was not: an edge rollout refreshed the shared web template, rebuilt every vhost, ran repairs and probed sites sitting on beta and stable. `repair` writes, so an edge release made changes to sites running older code."
brand: plain
status: shipped
status-note: "FILED AND FIXED 2026-08-17, from the release manager watching the 0.10.12 edge rollout: \"the updater attempted to update templates across all sites... we must leave them alone so we do not risk having partial updates such as template changes when they sit on older version\". The channel ladder gated the code and not the operations around it, which is half a ladder. Scope is now computed ONCE, before any phase touches anything, and every phase obeys it. The one thing that cannot be scoped - a shared Hestia template file - now says so where it happens."
---

# What was wrong

The per-site deploy obeyed the channel: `install.sh --channel-check` returns 3
for a site whose `update_channel` refuses the build, and the deploy exits before
touching it. That part worked.

Nothing else did.

```datatable
columns: Phase | Scoped before | Effect on an out-of-scope site
widths: 4.6cm | 2.6cm | X
bold: 1
tone: medium
---
Shared template refresh | no | stages a newer template it will render on its next rebuild
Proxy template assignment | no | changes its front-end template assignment
Vhost rebuild | no | rebuilds it, resetting docroot permissions
Per-site install | **yes** | correctly skipped
`repair --all` | no | **WRITES to it** - repairs a site the release was never meant to reach
`probe --all` | no | reports its exposure as a finding of this rollout
---
```

**`repair` is the serious one**, because it modifies. On the 0.10.12 rollout it
reported "1 clean, 1 repaired, 21 need a human" across a fleet where exactly one
site accepted the release. Something was repaired that this release was not for.

That is precisely the hazard a channel ladder exists to prevent: a change made to
a site running older code, at a moment chosen by a release it never accepted.

# What it also caused

The out-of-scope sites' exposures were reported as findings of the rollout, and
the rollout exited non-zero because of them - which is [[SM344]], where a
successful deploy was announced as a failure and the operator was told to bump
the version.

The two filings are one incident seen from two ends: this is why the wrong sites
were measured, SM344 is why measuring them broke the verdict.

# The fix

**Scope is computed once, before anything acts.** A pre-pass asks
`install.sh --channel-check` per discovered site and partitions the list. Every
later phase - proxy, rebuild, deploy, repair, probe, summary - iterates only the
in-scope set. Out-of-scope sites are named once, as untouched, and then not
mentioned again.

The channel decision is **not re-implemented in bash**. `--channel-check` already
answers it, reads only `lazysite.conf` and the manifest, changes nothing, and is
the same code the per-site deploy obeys. A second copy would be one fact in two
places, which is the defect class this project keeps closing.

`repair` and `probe` are now invoked `--domain` per in-scope site rather than
`--all`. A site is either in scope or left alone; there is no third category
where it gets touched a little.

## The one thing that cannot be scoped

The Hestia web template is a **shared file**. Every domain assigned to it renders
whatever version is in the template directory, at whatever moment its vhost is
next rebuilt - which may be an unrelated Hestia operation weeks later.

So refreshing it during an edge rollout stages a newer template for stable sites,
and the effect arrives late and detached from the release that caused it. That
cannot be fixed by scoping a loop; per-channel template names would fix it and
are more machinery than this warrants today.

It stays opt-in, and it now prints who else it reaches and how many. **The
default is that a routine deploy does not refresh it at all** - see the watcher
change below.

# The watcher

`inbox/lazysite-deploy.sh` passed `--rebuild` on **every** deploy, and
`--rebuild` implies `--templates`. So every edge cut refreshed the shared
template and rebuilt every vhost on the host. That was the immediate cause of
what the release manager saw.

Its default is now a plain deploy. `--rebuild` / `--templates` become
promotion-time flags, passed deliberately via `LAZYSITE_DEPLOY_FLAGS` when the
release actually changes the template or when promoting to the channel the
affected sites are on. The [[SM270]] ordering they exist for is unchanged and
still lives inside the updater.

# The rule this establishes

An edge release touches edge sites. A beta promotion touches beta sites. Only a
stable promotion touches stable sites. Nothing else - no template change, no
rebuild, no repair, no probe, no warning attributed to a rollout that could not
have caused it.

# Verification

- An edge rollout on a host of mostly-stable sites reports one in-scope site and
  touches exactly that one.
- The out-of-scope list is printed once, as untouched, and no later phase
  mentions those sites.
- `repair` and `probe` never run against a site whose channel refused the build.
- A shared-template refresh names how many out-of-scope sites it will reach.
- The default watcher invocation refreshes no template and rebuilds no vhost.

# Related

[[SM344]] (the verdict this broke), [[SM270]] (the refresh-rebuild-deploy
ordering, preserved), [[SM317]] and [[SM321]] (`repair` and `probe` as fleet
verbs), and `inbox/lazysite-deploy.sh`.
