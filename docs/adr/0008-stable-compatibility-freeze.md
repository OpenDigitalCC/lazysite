# 0008 - Compatibility freeze for the stable line

Status: Proposed
Date: 2026-07-18
Tags: release, stable, compatibility, support

## Context

ADR 0005 made a release's channel explicit (`edge` by default, `stable` only
on `release.sh --final`) and gave each site an `update_channel`. The 0.7.0
stable (2026-07-10) opened a five-year support commitment, but *what* that
support commits to has been implicit. The 0.7.x edge line has since added a
domain-owned access model (SM165), content history that follows renames
(SM175), multilingual language sets (SM179 P1-P8) and a run of manager work.
Before promoting the accumulated edge work to the next stable, we must state -
once - which surfaces customer sites and integrators may build against and rely
on for the life of the stable line, and which are internal and may change under
them.

Without this line, every edge change risks silently breaking a customer site or
an integrator's automation, and every refactor risks being treated as a breaking
change when it is not.

## Decision

The following are the **frozen public surface** of a stable major. Within a
stable major they change **additively only** - new keys/actions/vars/fields may
be added; existing ones keep their name, meaning, type and default. A breaking
change to any of them requires a new major and a documented migration.

1. **Site configuration** - the `lazysite.conf` keys and their semantics
   (including alias/domain keys, `update_channel`, `lang`/`lang_group`), as
   specified in `docs/IMPLEMENTOR.md` and `docs/OPERATOR.md`.
2. **Page front matter** - the documented front-matter fields (`title`,
   `subtitle`, `auth`, `layout`, `theme`, `register`, `tt_page_var`,
   `query_params`, `lang`, `meta_title`/`meta_desc`, `nocache`, `translated_from`,
   ...) and their behaviour.
3. **The layout/template contract** - the template variables the engine exposes
   to a layout (`page_title`, `site_name`, `content`, `nav`, `theme_assets`,
   `theme_css`, `languages`, `t`, `page_lang`, ...), and the layout/theme/
   component directory shape (D013: `layouts/NAME/layout.tt`,
   `themes/THEME/theme.json`, `components/`, `strings/<lang>.json`).
4. **The control API** - the action names, their required capability, their
   request/response shape, and the channel/CSRF rules (ADR 0003), as exercised
   by `whoami` / `describe-capabilities`.
5. **The MCP tool surface** - tool names, input/output schemas and annotations.
6. **WebDAV** - the paths served, the confinement rules (SM151/SM165), and the
   reserved `lazysite/` namespace.
7. **The CLI tools** - `lazysite-users`, `lazysite-domains`, `install.pl`
   (including `--channel-check` exit codes) and the other shipped `tools/`
   entry points: their verbs, flags and exit codes.
8. **Packaging + install layout** - the deb package set
   (`lazysite-common` + the environment debs), install paths, and the
   `release-manifest.json` / `sbom.json` the tarball ships.
9. **The capability model** - the capability names and what each unlocks
   (`docs/reference/capability-map.md`), and the channel/capability gate
   (ADR 0003).

The following are **explicitly NOT part of the contract** and may change in any
release, edge or stable, without a major bump:

- The internal Perl module layout under `lib/` (namespaces, function
  signatures, the deliberate processor/module split) - integrators call the
  API/CLI/MCP, never `Lazysite::*` directly.
- Cache formats and locations (`lazysite/cache/`), compiled-template artefacts,
  and the HTML mirror.
- Log line formats (application log, access log) - the audit trail's
  pipe-delimited record IS frozen (it is a compliance surface); the debug/app
  logs are not.
- The manager UI's HTML/CSS/JS internals - the *pages exist* and their
  capability gating is frozen, but their markup, class names and client code are
  free to change (the UI-consistency pass of this cycle is exactly such a
  change).
- Bundled starter content and the shipped layouts/themes catalogue - these are
  examples, versioned on their own cadence (the layouts repo), not part of the
  engine's contract.
- Engine-emitted chrome *wording* - the English strings may be reworded or
  localised (SM179 P8); the *mechanism* (`lazysite/i18n/<lang>.json`) is frozen.

## Rationale

The frozen set is exactly the surface a customer site, an integrator's
automation, or a delegated AI agent builds against. Freezing it - and no more -
lets the engine keep refactoring internals (the thing that makes iteration
fast) while giving the five-year commitment a concrete, testable meaning. Most
of the frozen surfaces already have a guard test (the control-API dispatch,
capability map, git/audit guarantees, domain confinement, the vhost hardening);
this ADR makes their stability a stated contract rather than an accident.

Drawing the line at "the API/CLI/MCP/conf, not the code" matches how the product
is actually consumed - nobody links `Lazysite::*` - and matches ADR 0001's
existing stance that even the processor's module-free duplication is an
internal choice.

## Consequences

- A pre-stable audit can now check each frozen surface for accidental drift, and
  a regression test can be added for any surface that lacks one.
- Edge may still move fast: an edge change that only touches a non-frozen surface
  (module layout, cache, manager markup) carries no compatibility risk by
  definition.
- A genuinely breaking change becomes a visible, deliberate act: it forces a
  major bump and a migration note, rather than slipping out in a patch.
- The Declaration of Conformity and the stable release notes can reference this
  ADR as the definition of the supported interface.
- New public surface added on edge (e.g. a new conf key or API action) joins the
  freeze automatically once a stable ships carrying it - so new work should be
  designed additively from the start.
