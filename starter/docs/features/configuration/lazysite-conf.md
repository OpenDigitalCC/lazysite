---
title: lazysite.conf
subtitle: Define site-wide variables for the view template and page content.
tags:
  - configuration
  - template
---

## lazysite.conf

The site configuration file defines variables available in every page
and the view template. It uses a simple `key: value` format with one
variable per line.

### Location

    public_html/lazysite/lazysite.conf

### Syntax

    site_name: My Website
    site_url: ${REQUEST_SCHEME}://${SERVER_NAME}
    footer_text: Copyright 2024

### Value types

Literal string:

    site_name: My Website

Environment variable interpolation:

    site_url: ${REQUEST_SCHEME}://${SERVER_NAME}

Only allowlisted CGI variables are interpolated: `SERVER_NAME`,
`SERVER_PORT`, `REQUEST_SCHEME`, `HTTPS`, `REQUEST_URI`, `REDIRECT_URL`,
`DOCUMENT_ROOT`, `SERVER_ADMIN`. Other `${...}` references are left
as literal text. `HTTP_HOST` is intentionally excluded as it is
request-supplied and untrusted.

Remote URL fetch:

    latest_version: url:https://example.com/version.txt

Directory scan:

    all_posts: scan:/blog/*.md sort=date desc

### Special keys

- `theme` - set the site-wide view template name or remote URL
- `nav_file` - override the navigation file path (docroot-relative,
  default: `lazysite/nav.conf`)

### Example

    site_name: My Blog
    site_url: ${REQUEST_SCHEME}://${SERVER_NAME}
    theme: default
    nav_file: lazysite/nav.conf
    copyright: 2024 Author Name

### Notes

- No comment syntax - every non-empty line matching `key: value` is
  parsed
- All variables are available in page content as `[% site_name %]`
  and in the view template
- The `scan:` prefix works in `lazysite.conf` the same as in
  `tt_page_var`
- [Config path override](/docs/features/configuration/conf-path-override) -
  use a different config file location
