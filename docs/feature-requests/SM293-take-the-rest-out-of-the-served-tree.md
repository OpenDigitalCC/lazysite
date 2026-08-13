---
title: "SM293 - Take the rest out of the served tree"
subtitle: "SM286 step 1 moved gated content out of the document root. Config, credentials, snapshots and the generated registries are still in it, and every one of them is still defended by a rule in a config file we do not control."
brand: plain
status: candidate
status-note: "FILED 2026-08-13, carrying forward steps 2-5 of SM286, which is closed on step 1 (the private content store, shipped on main unreleased). Nothing here is started. Step 2 (move lazysite/ out of the docroot) is the one with a live argument behind it: SM283's proxy would have served lazysite/backups/preinstall-*.tar.gz on any host whose static extension list includes gz."
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

## Step 3 - registries and sidecars

Serve `sitemap.xml`, `llms.txt`, `robots.txt` and the feeds **from the engine**
rather than writing files at the docroot root that shadow it. That removes the
SM248 routes: a secondary domain served the primary's statics precisely because
these files sit at a path the front end resolves before the engine is consulted.

Land [[SM245]] (sidecars into an optional plugin), which removes the `.brief`
deny.

## Step 4 - demote the trust-header strip

In the documentation, from "required" to "hardening we recommend". The in-app
gate is the control and is enforced by lint. Documentation-only, but it changes
what an operator believes is load-bearing, which is the point of the whole
direction.

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
