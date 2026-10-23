---
title: Config path override
subtitle: Use a custom lazysite.conf path via command-line arg or environment variable.
tags:
  - configuration
  - development
---

## Config path override

Override the default `lazysite.conf` location using a command-line
argument or environment variable. Useful for staging environments,
testing alternate configs, or deployments where the conf lives
outside the docroot.

Most sites do not need this. Each Apache vhost has its own
`DOCUMENT_ROOT`, so each site automatically gets its own
`lazysite.conf` at `DOCROOT/lazysite/lazysite.conf`. Multiple
sites on one server each have their own docroot and their own
config - no override is needed.

### Priority order

1. `--conf PATH` command-line argument (highest priority)
2. `LAZYSITE_CONF` environment variable
3. Default: `DOCROOT/lazysite/lazysite.conf`

### Syntax

Command-line:

    perl cgi-bin/lazysite-processor.pl --conf /path/to/custom.conf

Environment variable:

    LAZYSITE_CONF=/path/to/custom.conf

### Example

Test with a different configuration:

    LAZYSITE_CONF=/tmp/test.conf \
    DOCUMENT_ROOT=/var/www/html \
    REDIRECT_URL=/index \
      perl cgi-bin/lazysite-processor.pl

### Notes

- The path is used as-is - it is not resolved relative to the docroot
- If the specified file does not exist, site variables will be empty
  (no error is raised - `resolve_site_vars` returns early)
- The `--conf` argument requires the path as the next argument
  (space-separated, not `=`)
- [lazysite.conf](/docs/features/configuration/lazysite-conf) -
  configuration file format
