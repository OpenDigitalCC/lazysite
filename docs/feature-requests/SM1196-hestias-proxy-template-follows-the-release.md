---
id: SM1196
title: "SM1196: Hestia's proxy template follows the release"
subtitle: "Hestia renders a vhost from its own copy of lazysite's templates, and nothing refreshed that copy; the rollout now compares and replaces it, and the domain tool names a stale one."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-19
raised-by: inbox/2026-10-19-test-plan-01510-results.md, finding F-6 re-test (edge's host)
area: security
status-note: "SHIPPED (PENDING) on n687: installers/hestia/lazysite-hestia-update-all.sh (refresh_template, domains_on_template), tools/lazysite-hestia-domain.pl (template_state, template_hint, proxy_template_hint); t/tools/186."
---

# What happened

Edge's host, 2026-10-19, the F-6 re-test: after `v-rebuild-web-domain` the vhost
still passed the client's `X-Forwarded-For` through, and

```
grep -n "X-Forwarded-For" /usr/local/hestia/data/templates/web/nginx/lazysite-proxy.*tpl
```

found NO match. Hestia's installed copy of lazysite's proxy template predates
SM929 (v0.15.2), so every rebuild re-renders the old one. SM1194 made the rollout
report the exposure; it could not remove it, because a rebuild reads the very
template that is old.

The cause, verified in the repo: Hestia's copy is a one-off manual step
(`debian/lazysite-hestia.README.Debian` step 3, `installers/hestia/INSTALL-RUNBOOK.md`:
`cp /usr/share/lazysite-hestia/templates/lazysite-proxy.* /usr/local/hestia/data/templates/web/nginx/`).
An upgrade refreshes `/usr/share/lazysite-hestia/templates`
(`debian/lazysite-hestia.install`) and nothing refreshes Hestia's copy.
`proxy_template_hint` in the domain tool checked only that the file EXISTS. The
updater's `--templates` copy overwrote blindly and only with the flag, and its
VHOST column said "render an older template - rebuild", which cannot help while
the installed template is old.

The Apache web templates carry the same risk: `lazysite-cgi.*` and
`lazysite-fcgi.*` are copied to `apache2/php-fpm/` by the same one-off step and
are never refreshed (and `lazysite-app.*`, the tarball template, only with
`--templates`).

# What shipped

- `lazysite-hestia-update-all.sh` compares, on every run (list mode excepted,
  which changes nothing), each lazysite template Hestia has installed with the
  release's copy (`$STAGE/installers/hestia`, or `/usr/share/lazysite-hestia/templates`
  when the stage has none) and replaces one that differs. The old copy is kept
  beside it as `NAME.EXT.bak-TIMESTAMP`, an ending Hestia does not list as a
  template. Each replacement is reported; an identical copy is untouched and
  silent. A template not installed is installed only under `--templates` (as
  before); cgi/fcgi are refreshed where present and never installed by a rollout.
  The domains on a replaced template are read from Hestia's `web.conf` and named
  as needing a rebuild; `--rebuild` rebuilds them (also those the rollout does not
  otherwise manage). A refresh that cannot write is a `FAILURE:` line and the
  rollout exits 1. Order: refresh, rebuild, deploy, then SM1194's check of the
  rendered files.
- `lazysite-hestia-domain`'s hints (`template_hint`, `proxy_template_hint`) report
  a copy that differs from the release's as STALE, with the copy command and the
  rebuild, not only a missing one. Test knobs `LAZYSITE_HESTIA_TEMPLATES` and
  `LAZYSITE_TEMPLATE_SRC`.
- The debs: `debian/` has one maintainer script, `lazysite-common.postinst`
  (systemd daemon-reload). `debian/lazysite-hestia.install` records the decision
  that the templates are NOT installed into Hestia's tree ("/usr/local/hestia is
  not deb territory"), so the deb is unchanged; the docs say to repeat the copy
  after every upgrade, and the domain tool says when the copy is stale.
- Docs: README.Debian, INSTALL-RUNBOOK.md, UPGRADE.md, with the probe
  (`grep -n "X-Forwarded-For" .../lazysite-proxy.*tpl` and a request carrying
  `X-Forwarded-For: 192.0.2.55`).
