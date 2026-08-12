---
title: "SM286 - The front end should make no decisions lazysite depends on"
subtitle: "Three incidents, one cause: security living in config we do not control and mostly cannot see. The direction is self-sufficiency, and the largest single step is that gated content stops living in the document root."
brand: plain
status: candidate
status-note: "FILED 2026-08-12 on the operator's direction, given after 0.10.7 shipped a Hestia nginx proxy template: 'we are getting too much into the upstream machinery... my direction is toward self-sufficiency in lazysite, therefore no adding anything to nginx and reducing or ideally removing any apache configs.' NOT STARTED. This filing reverses the shape of the SM283 fix, which is now transitional. Sized L overall; step 1 is M and delivers most of the value."
---

# SM286 - the front end should make no decisions

## The pattern, stated once

Three defects in three releases, all the same cause:

SM248
: a secondary domain served the primary site's `sitemap.xml`, because the front
  end answered from disk before the engine's per-Host handler could run.

SM268 H17
: every Apache ACL rule lacked `PT`, so on the Hestia layout the rewrite target
  did not exist and **every** static file 404'd once a site had an ACL store.
  Fail-closed, found immediately.

SM283
: the Hestia nginx proxy served gated images, PDFs and archives off the docroot
  by file extension. Fail-open, live across a fleet for weeks, found by an agent
  uploading the same bytes under five names.

Each time the engine was correct. Each time the failure was in front-end
configuration - which lazysite ships as templates, cannot test where it is
installed, and on most deployments **cannot even see**. The operator's summary
is the accurate one: this is upstream machinery, and every rule we put there is
another point of fragility we do not own.

## The direction

**The front end must make no decision lazysite's correctness or security
depends on.** Ideally it makes one decision: *forward this request to lazysite*.

Stated as a test any future change can be held to: if an operator replaced our
vhost with a single "proxy everything to the engine" rule, would anything be
exposed or broken? Today the answer is yes, in several places. That is the work.

## The four shapes, and what each needs

Dev server (`tools/lazysite-server.pl`)
: local only, no front end at all. **It already implements the whole contract**,
  including the static-ACL decision (`t/unit/tools/03`). This is the existence
  proof: everything the vhost does, the engine can do. It is currently labelled
  evaluation-only, and under this direction it is closer to the destination than
  anything else we ship.

Deb behind Apache / nginx / something else
: the shape we have. Today it needs ~30 lines of security-bearing config,
  written four different ways, and we mostly have no access to verify it.

Container
: forward-everything is the only sane contract. Any per-front-end rule we
  require here is a rule the image cannot guarantee.

Because we mostly have no access upstream, **anything we require of the front
end is unverifiable in production**. That is the argument, independent of taste.

## What the vhost actually carries, and what can go

Audit of `installers/hestia/lazysite-cgi.tpl`, block by block.

```datatable
columns: Block | Verdict
widths: 6.5cm | X
text: 2
bold: 1
tone: medium
---
SM223 ACL rewrites (~20 lines) | **REMOVABLE** - step 1 below. The largest, most fragile block, and the one that has failed twice.
`<Location /lazysite/>` deny | **REMOVABLE** - step 2. Nothing needs denying if nothing is there.
`<FilesMatch \.brief>` deny | **REMOVABLE** - step 3, and SM245 already proposes moving sidecars to a plugin.
Per-domain registry routes (SM248) | **REMOVABLE** - step 3. They exist only because a real file at the docroot root shadows the engine's correct per-Host handler.
SM133 `.shtml`/`.html` sibling fallbacks | **REMOVABLE** - the processor already does this for non-Apache fronts. The Apache copy is a duplicate of engine behaviour.
`RequestHeader unset X-Remote-*` | **DEMOTE** to optional hardening. The in-app trust gate is the real control, `t/lint/13` enforces it on every CGI, and that test's own comment already calls the vhost strip "a backstop".
`ScriptAlias` + the auth-wrapper rewrite | **IRREDUCIBLE while we are a CGI.** This is how the engine is invoked at all. It collapses to nothing in the daemon shape.
`FallbackResource` | **IRREDUCIBLE**, and in the target shape it is the ONLY rule - "everything unmatched goes to lazysite" becomes "everything goes to lazysite".
`<Directory>` options, `SetEnvIf Authorization` | Keep. Hardening and DAV plumbing, not decisions about our content.
```

So the security-bearing part of the vhost is removable, and what remains is
plumbing.

## Step 1 - gated content never lives in the document root

This is the change that matters, and most of the value is here.

Today a protected section is a normal file in the docroot plus an entry in
`acls.json`, and **every front end must be told not to serve it**. That is a
rule we cannot verify on 17 production hosts, written four ways, and it has
failed twice.

Instead: when a section is protected, its content moves to a private tree
**outside the document root** (the Hestia layout already gives us a sibling of
`public_html`; the deb and container shapes can declare one). The engine reads
it and applies the ACL. **The front end has no path to it, so no front-end rule
is required, and none can be got wrong.**

What this buys:

- the SM223 rewrite block is deleted from ten shipped configs and from the
  generator;
- SM283 becomes structurally impossible rather than fixed-per-front-end;
- the ACL stops being advisory-until-configured on any deployment we cannot see;
- a site with no protected sections is completely unaffected, as now.

What it costs, honestly:

- protecting a section becomes a **move**, not a metadata write. It stays a pure
  content action - no vhost change, no reload - but it must be atomic, and a
  half-completed move must fail closed (content stays private, operation
  reports failure);
- all four authoring surfaces (manager, MCP, WebDAV, CLI) must resolve both
  trees, and the page cache for a gated page has to live in the private one;
- a naive write straight to the public path could recreate a public copy, so the
  writers need a single choke point that knows which tree a path belongs to;
- ADR 0001 still applies: the render path loads no Lazysite modules, so the
  processor's copy of the resolution has to stay module-free and pinned by lint,
  as `_acl_allows_read` already is.

### Step 1 progress: the foundation is built (2026-08-12)

`Lazysite::Private` ships with `t/unit/lib/20`, and **nothing is wired to it
yet** - deliberately, because half-wiring it would break the gated-content path
on whichever surface was left out, and that path is the one this whole filing is
about.

The decisions, so the next session re-derives none of them:

**Location.** `dirname($DOCROOT)/lazysite-private` - a **sibling** of the
docroot, never a subdirectory, since a subdirectory is exactly what a front end
serves. The docroot's parent already holds engine files on the Hestia layout
(`tools/`, `lazysite-log.pl`), so this follows a convention rather than
inventing one. Not hidden with a leading dot: an operator should be able to see
where their content went.

**The invariant: a path is in exactly one tree.** A copy left in the docroot is
the exposure being removed, so every failure path leaves the content on one side
and says which. `move_in` on a missing path succeeds quietly - gating a section
before filling it is ordinary.

**Atomicity.** `rename` is atomic within a filesystem and moves a whole
directory in one step, which is what makes protecting a *section* safe: there is
no window in which half of it is public. Cross-device falls back to
copy-verify-unlink, and a folder across devices is refused outright rather than
walked.

**Both-trees resolution prefers PRIVATE**, which is a fail-safe choice rather
than a preference. If a stray public copy appears, the front end can already
serve it; having the engine serve the public one too would hide the fault from
anything comparing them. `stray_public()` reports it, and a second `move_in`
refuses rather than overwriting the governed copy.

### Step 1 remaining: the wiring, which is the bulk

Each of these must resolve BOTH trees before anything is moved in anger:

- **the processor** - `_serve_content_static` and the page path, plus a
  module-free copy of the resolver (ADR 0001), pinned like `_acl_allows_read`;
- **the manager, MCP, WebDAV** - list, read, save, move, copy, delete;
- **the page cache** for a gated page, which must land in the private tree or it
  re-publishes the content it was protecting;
- **one write choke point**, so a naive save cannot recreate a public copy;
- **`action_acl_set` / `action_acl_remove`** to move in and out, reporting a
  failed move as a failed protect;
- **backups, site packages and content history**, which all walk the docroot
  today and would silently stop covering gated content.

Sequence it so the resolver lands everywhere FIRST and the move last: with
resolution in place and nothing moved, every surface behaves exactly as now, and
the move becomes a single switch with a real rollback.

## Steps 2-5

2. **Move `lazysite/` out of the document root.** Config, credentials, audit
   logs and pre-install snapshots are not content and have no business in a
   served tree. Deletes the `/lazysite/` deny from every template. This is the
   same argument as step 1 and independently worth doing - SM283's proxy would
   have served `lazysite/backups/preinstall-*.tar.gz` on any host whose
   extension list includes `gz`.

3. **Registries and sidecars.** Serve `sitemap.xml`, `llms.txt`, `robots.txt`
   and the feeds from the engine rather than writing files at the docroot root
   that shadow it - that removes the SM248 routes. Land SM245 (sidecars into a
   plugin), which removes the `.brief` deny.

4. **Demote the trust-header strip** in the docs from "required" to "hardening
   we recommend", since the in-app gate is the control and is enforced by lint.
   Documentation-only, but it changes what an operator believes is load-bearing.

5. **The daemon shape.** With 1-4 done, the front end's whole job is "forward
   everything". At that point the natural artefact is lazysite speaking HTTP or
   FastCGI itself - which the pool already does for the render path - with a
   documented one-line proxy rule per front end and no templates at all.

## What happens to the SM283 template

It ships in 0.10.7 and it closes a live disclosure, so it stays. But it is
**transitional**, and this filing supersedes it as the direction. Two immediate
consequences:

- For an affected domain, **turning that domain's nginx proxy off is the more
  aligned remedy** than installing the template: it removes a front-end decision
  rather than adding one. The template is for operators who want the static
  acceleration and accept the config.
- No further front-end capability should be added. If step 1 lands, the template
  becomes inert for exactly the reason it should: there is nothing at that path
  for a proxy to leak.

## Relationship to SM285

[[SM285]] proposes a self-probe that asks the running site whether a gated file
can be fetched anonymously. Under this filing that probe should eventually
always pass trivially - which is the point. It remains worth building **first**,
because it is small, it verifies every step of this work from the outside, and
until step 1 lands it is the only thing that can tell an operator whether a
deployment we cannot see is exposed.

## Acceptance for the direction as a whole

An operator can replace every shipped vhost template with one rule - forward
everything to lazysite - and:

- no content is exposed that the engine would refuse;
- no per-domain or per-extension list appears anywhere in the deployment;
- the dev server, the deb and the container behave identically on the same
  content;
- the shipped templates still exist, but as **performance** options whose
  absence costs speed and never correctness.

## Related

[[SM283]] (the incident that prompted this, and the template it superseded),
[[SM248]], [[SM268]] H17, [[SM223]] (the engine enforcement, correct
throughout), [[SM245]] (sidecars to a plugin), [[SM285]] (the self-probe),
ADR 0001 (the module-free render path), and
`docs/reference/webserver-wiring.md`, which is the document this work would
progressively shorten to nothing.
