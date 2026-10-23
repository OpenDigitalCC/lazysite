---
id: SM1249
title: "SM1249: the Hestia site list sees every lazysite template"
subtitle: "lazysite-hestia-list.sh matched only the lazysite-app web template, so it reported 0 sites on a host whose sites use lazysite-proxy and the cgi/fcgi templates. It now lists sites on every lazysite template, and the batch updater keeps its lazysite-app scope by asking for it."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-22
raised-by: "the release manager (task #379, part 1)"
area: installers
status-note: "SHIPPED (0.16.1) on n724: the lister's default is every lazysite template; --tpl NAME narrows; the updater passes --tpl lazysite-app. t/tools/249. Part 2 (an automatic rebuild) is left for a ruling."
---

# What happened

`lazysite-hestia-list.sh` defaulted to `--tpl lazysite-app`. On a host whose sites use
lazysite-proxy, it reported 0 sites.

# The cause

- The lister kept a domain only when its web.conf line contained `TPL='lazysite-app'`.
  A deb-flow site is on `lazysite-cgi` or `lazysite-fcgi`, usually with `lazysite-proxy`
  in front, and some older sites are on `lazysite`.
- The match was a bare substring. `TPL='...'` is also the tail of `PROXY_TPL='...'` and
  `BACKEND_TPL='...'`, so `--tpl NAME` matched a proxy template as if it were the web
  template.

# What shipped

- By default, a domain is a lazysite site when its web template is `lazysite`,
  `lazysite-app`, `lazysite-cgi` or `lazysite-fcgi`, or its proxy template is
  `lazysite-proxy`. Each field is read by name. The report shows `tpl=<web template>`
  per site, and its banner names the templates matched.
- `--tpl NAME` narrows the list to one template, which may be a web or a proxy template.
- The batch updater passes `--tpl lazysite-app`, so what it deploys is unchanged: the
  tarball flow, whose template that is. Its union now covers every lazysite template, so
  a domain on another lazysite template is listed as excluded rather than missing.
- `lazysite repair/probe --domain` on a host with no registry discovers through the
  lister, so they now address cgi, fcgi and proxy-only sites too.

# Not done: part 2, for a ruling

Part 2 of #379 asks whether the updater should rebuild a vhost unasked when it renders an
older lazysite template and the site trusts the default ranges, which is the
X-Forwarded-For pass-through FAILURE (SM1194). That would change a vhost without
`--rebuild`, so it is left to the release manager. The options are in the n724 report.
