---
title: "SM293 - Take the rest out of the served tree"
subtitle: "SM286 step 1 moved gated content out of the document root. Config, credentials, snapshots and the generated registries are still in it, and every one of them is still defended by a rule in a config file we do not control."
brand: plain
status: candidate
status-note: "FILED 2026-08-13, carrying forward steps 2-5 of SM286 (closed on step 1). STEPS 2a, 2b, 3 and 4 ALL SHIPPED 2026-08-13 on main (unreleased), after the operator settled both open questions: automation per-domain-or-all with a version gate for step 2b, and generated-on-request-with-a-cache for step 3. The engine tree can now be moved out of the document root with `lazysite migrate-engine-tree`, and the registries are no longer written into it at all. Only STEP 5 (the daemon shape) remains, and it is a new artefact rather than a removal."
---

# SM293 - the rest of the served tree

## Why this is a separate filing

[[SM286]] made one argument and took one step with it. The argument was that
security living in front-end configuration is security lazysite ships as a
template, cannot test where it is installed, and on most deployments cannot see
- and that the answer is to stop putting things a front end must be told about
in the tree the front end serves.

Step 1 applied that to **gated content**, and is done. Everything else the
shipped vhost templates defend is still there, defended the same way. That is
the work, and it is separate work: the store was one mechanism landing at once,
whereas each item below is its own removal with its own risk.

## What is still in the document root, and what defends it

| In the served tree | Defended by | Removed by |
|---|---|---|
| `lazysite/` - config, credentials, audit log, pre-install snapshots | a `/lazysite/` deny in every shipped template | step 2 |
| `sitemap.xml`, `llms.txt`, `robots.txt`, the feeds | nothing - they are files at the docroot root that shadow the engine's routes | step 3 |
| `.brief` sidecars | a `.brief` deny in every template | step 3, via [[SM245]] |

## Step 2a - one resolver, and nothing moves - SHIPPED

`Lazysite::Paths::lazysite_dir` answers "where does this site keep its engine
tree", and every surface asks it instead of computing an answer. The answer
today is the same path as before, so nothing has moved.

**Discovery, not assumption**, which is what makes the flip safe when it comes:
a site migrates by MOVING the directory and nothing else - no config key, no flag
day, no version gate. Both layouts work on one code path, so an upgrade cannot
half-migrate a site into an unbootable state. Outside wins when both exist,
because a tree left inside the docroot is the exposure.

`t/lint/37` pins it three ways: the processor's module-free copy (ADR 0001) is
DRIVEN and compared against the module rather than eyeballed; that copy must stay
module-free and take its docroot as an argument; and nothing anywhere may rebuild
`<docroot>/lazysite` for itself. The third check found thirteen call sites on the
day it was written, and the tests found two more that mattered more:
`lazysite-check`'s "is this a lazysite docroot?" guard would have REJECTED a
migrated site outright, and the users tool would have created a second, empty
account store inside the docroot and managed that one.

## Step 2 - move `lazysite/` out of the document root

Config, credentials, audit logs and pre-install snapshots are not content and
have no business in a served tree. Deletes the `/lazysite/` deny from every
template.

This is the same argument as SM286 step 1 and independently worth doing, with a
concrete instance behind it: **SM283's proxy would have served
`lazysite/backups/preinstall-*.tar.gz`** on any host whose static extension list
includes `gz`. A pre-install snapshot is the whole site, including the account
store.

The private store built for step 1 already establishes the convention - a
sibling of the document root, named for it - so the location question is
settled. What is not settled is the migration: `lazysite/` is referenced by
every surface, by installers, by the Hestia hook, and by operators' own scripts.

## Step 2b - the migration - SHIPPED

`lazysite migrate-engine-tree --docroot D | --all`, dry-run by default,
`--apply` to act, `--back` to reverse, `--min-version` to gate on the release
having reached a site. One rename, atomic within a filesystem; it REFUSES across
filesystems rather than falling back to a copy, because a half-copied auth store
is the worst outcome available. Idempotent, so a fleet run is safe to repeat and
safe on a mixed fleet. As root, `--all` drops to each site's owner exactly as
`upgrade --all` does. A half-migrated site is refused, not repaired.

The rename was the easy part. Two things had to change or the migration would
have been a trap:

- **install.pl** writes into the engine tree, so an installer computing
  `<docroot>/lazysite` would recreate it inside the docroot on the very next
  upgrade - and a site in both places works perfectly while publishing its
  credentials. The classification targets use a `{LAZYSITE}` placeholder now.
- **lazysite-check** writes its permission model docroot-relative, so on a
  migrated site all six consumption sites would have skipped the entire engine
  tree and reported a clean bill of health while verifying nothing.

### The original note, kept because the reasoning still applies

**Needed the release manager.** Step 2a made the engine ASK where its tree is;
the answer today is still `<docroot>/lazysite`. Flipping means moving that
directory on every existing site, and it is a different kind of change from the
refactor:

- it touches **live credentials** on 17 production sites;
- it needs an `install.pl` migration with a rollback, because a half-move is the
  one state that is both broken and invisible (the engine reads the new tree
  while the front end can still serve the old one);
- `lazysite-check` already FAILs on that half-migrated state, which is what
  makes the migration verifiable rather than hopeful.

The discovery rule means a site can be migrated **one at a time**, by hand, with
`mv`, and moved back the same way. That is the cheapest possible pilot and it
needs no release at all - only step 2a, which is shipped.

## Step 3 - registries and sidecars

**DECIDED AND SHIPPED**: generated-on-request with a cache. The operator's
reasoning, 2026-08-13 - it uses the machinery already there, a registry being a
little stale does not matter, and it keeps a potentially high-demand file out of
the document root.

The generated copy goes to `$CACHE_BASE/registries/<content-root-key>/`, keyed
per content root, and the engine serves it; the TTL is unchanged, so it costs one
render per TTL rather than one per crawler hit. An operator's own sitemap.xml
still wins. `lazysite-check` names any leftover file from before the change,
because a file left at the old path goes on being served and never refreshed -
WARN, not FAIL, since a stale sitemap is an SEO problem and may have been
authored deliberately.

Three defects found while building it, all mine: a file-scoped `my` hash below
the main body that was empty at serve time (the SM285 trap, in the same file that
documents it); serving only the four shipped names, which quietly removed the
ability to define your own registry; and a missing Status line.

### The decision as it stood

Serve `sitemap.xml`, `llms.txt`, `robots.txt` and the feeds **from the engine**
rather than writing files at the docroot root that shadow it. That removes the
SM248 routes: a secondary domain served the primary's statics precisely because
these files sit at a path the front end resolves before the engine is consulted.

What makes it different from step 2: **these artefacts are public by design.**
SM248 was the wrong domain's sitemap being served, not private data being
disclosed. So the gain here is architectural - fewer front-end rules, one less
thing to get wrong per deployment - and not the closing of an exposure.

The cost is real and lands on the artefacts crawlers fetch most: today the front
end serves `sitemap.xml` from disk, and engine-served means a CGI invocation per
request. The engine already has the serving half (`_serve_content_static` is the
portable net for content-rooted hosts); what changes is that the files stop being
written, which is also what makes the SM248 routes removable.

So the question to settle before building it is whether that trade is wanted:
generated-on-request with a cache, or keep the files and keep the routes.

Land [[SM245]] (sidecars into an optional plugin), which removes the `.brief`
deny.

## Step 4 - demote the trust-header strip - SHIPPED

From "required" to "recommended hardening", in
`docs/reference/webserver-wiring.md`.

**The filing said the in-app gate was "enforced by lint". It was not** - it was
behaviour-tested on two surfaces and pinned nowhere. So the lint came first:
`t/lint/38` asserts that every surface which READS a trust header also gates it
on the auth wrapper having vouched for the request, keyed on reading rather than
a fixed file list, because a NEW surface that starts believing one is the case
that matters. It also asserts the gate DELETES the headers rather than only
logging them.

Demoting the doc first would have been the very thing this programme exists to
stop: prose asserting a control that nothing enforced.

## Step 5 - the daemon shape

With 2-4 done, the front end's whole job is "forward everything". At that point
the natural artefact is lazysite speaking HTTP or FastCGI itself - which the
pool already does for the render path - with a documented one-line proxy rule
per front end and no templates at all.

## Acceptance

Unchanged from SM286, and repeated here because this filing now owns it. An
operator can replace every shipped vhost template with one rule - forward
everything to lazysite - and:

- no content is exposed that the engine would refuse;
- no per-domain or per-extension list appears anywhere in the deployment;
- the dev server, the deb and the container behave identically on the same
  content;
- the shipped templates still exist, but as **performance** options whose
  absence costs speed and never correctness.

The first two are already true for gated content. They are not true for
anything else in the table above.

## Related

[[SM286]] (closed on step 1; this carries its steps 2-5), [[SM283]] (the
incident, and the transitional nginx template this direction supersedes),
[[SM248]] (which step 3 removes the route for), [[SM245]] (sidecars to a
plugin), [[SM285]] (the self-probe that verifies each step from outside), and
`docs/reference/webserver-wiring.md`, which this work progressively shortens to
nothing.
