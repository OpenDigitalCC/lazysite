---
title: Move a site (site packages / content migration)
---

A **site package** is a portable snapshot of one domain's site. Use it to hand an
agency demo over to a client's own instance, or to copy a site to another domain
on the same server.

A package contains just that one site:

- its content (all the pages and assets under the domain's content folder),
- its navigation menu,
- the theme and layout it uses (self-contained, so it works on any instance),
- its presentation settings (title, site address, etc.).

It deliberately leaves out plugins, instance settings and anything secret, so a
package is safe to send to another instance and carries nobody else's data.

## Who can do it

The `manage_domains` capability, plus access to the domain being moved. It is a
domain-management operation, not day-to-day content editing.

## The two steps

Move a site
: **Package** it on the source (the "back up" step), then **apply** it on the
  target. Same server or a different one - the only difference is whether you
  have to carry the file across.

Same instance (one domain to another)
: 1. Package the source domain. 2. Register the target domain (Domains page) if
  it does not exist yet. 3. Apply the package to the target domain.

Different instance (agency demo to a client's instance)
: 1. Package the source domain and **download** it. 2. On the client's instance,
  **upload** the package. 3. Register the target domain (or use the default
  site). 4. Apply the package.

Applying **overwrites the target site**, so it always takes a safety snapshot
first, and the change is recorded in content history where that is enabled - you
can roll back.

## Asking an AI agent to do it

A connected agent (Claude / an MCP client) has the tools and the recipe built in.
You can simply ask, for example:

> "Package the site on `demo.example` and apply it to `clienta.com`."

Behind the scenes the agent follows the `migrate-site` recipe it gets from
`describe_capabilities`: `site_backup` on the source, then (if the instances
differ) download + upload, then `site_apply` on the target, then a preview to
confirm. It will ask you to register the target domain first if that is needed.

## From the command line

```bash
lazysite-site --docroot DIR backup --host demo.example
lazysite-site --docroot DIR apply  --package lazysite-site-demo.example-<stamp>.tar.gz \
    --host clienta.com --clean
```

`--host` on `apply` names the target domain (omit it to apply to the default
site); `--clean` clears the target content folder first.

## What lazysite does not do

lazysite moves the **lazysite side** of a site. DNS, the web-server domain alias
and the TLS certificate for the new domain are the operator's / Hestia's job -
set those up first, then apply the package. Use the domain **Check** on the
Domains page to confirm DNS and HTTPS are in place.
