---
title: Static site generation
subtitle: Pre-render all pages for deployment to static hosting.
tags:
  - development
---

## Static site generation

The `build-static.sh` script renders every `.md` and `.url` source file
into static HTML for deployment to any web server or static hosting
service.

### Invocation

    bash tools/build-static.sh <scheme://hostname> [output-dir]

### Arguments

- `scheme://hostname` (required) - base URL of the site. Sets
  `SERVER_NAME` and `REQUEST_SCHEME` for correct URL interpolation.
- `output-dir` (optional) - directory to write the generated site.
  Defaults to in-place build in `public_html`.

### Example

Build in-place:

    bash tools/build-static.sh https://example.com

Build to a separate output directory:

    bash tools/build-static.sh https://example.com ./dist

Build and deploy:

    bash tools/build-static.sh https://example.com ./dist
    rsync -av --delete ./dist/ user@host:/var/www/html/

### Behaviour

1. Locates the docroot (`public_html/` or current directory)
2. If an output directory is given, copies source files there
   (excluding `.html` cache files)
3. Clears all existing `.html` files (except under `lazysite/`)
4. Processes every `.md` and `.url` file through the processor
5. Reports OK/FAIL for each page
6. If an output directory was used, removes `.md` and `.url` source
   files from the output

### Notes

- The processor must be at `cgi-bin/lazysite-processor.pl` relative
  to the docroot (checked at both `../cgi-bin/` and `./cgi-bin/`)
- Remote `.url` pages are fetched during the build
- `SERVER_PORT` is set to 443 and `HTTPS` to "on" during the build
- The script exits with status 1 if any pages fail to render
- [Cache management](/docs/features/development/cache-management) -
  how caching works during normal operation
