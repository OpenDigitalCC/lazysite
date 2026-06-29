---
title: Troubleshooting & migrating
subtitle: Diagnosing problems, and moving content in from other tools.
register:
  - sitemap.xml
  - llms.txt
---

## Migrating from other tools

Pico CMS
: Content migrates directly. Copy your Pico `content/` files to the docroot and rename `Title:` to `title:` and `Description:` to `subtitle:` in front matter. Replace Pico theme templates with a `lazysite/themes/default/view.tt` file. One-liner to convert front matter keys across all files: `find public_html -name "*.md" | xargs sed -i 's/^Title:/title:/;s/^Description:/subtitle:/'`

Hugo
: Content files require no changes  -  Hugo and lazysite use the same front matter format. What needs replacing is the template system: `view.tt` replaces your Hugo `baseof.html` or equivalent base template.

## Troubleshooting

### Run the processor manually

The most direct way to diagnose a page error:

```bash
REDIRECT_URL=/about \
DOCUMENT_ROOT=/home/username/web/example.com/public_html \
  perl /home/username/web/example.com/cgi-bin/lazysite-processor.pl
```

Prints full HTML output or Perl errors to the terminal. Adjust `REDIRECT_URL` to the failing page path.

### Check the error log

```bash
tail -50 /home/username/web/example.com/logs/example.com.error.log
```

`End of script output before headers`
: The script crashed before printing anything. Run the processor manually to see the Perl error.

`lazysite: Cannot write cache file ... Fix with: chmod g+ws`
: The web server cannot write the generated `.html` to the docroot. Pages render correctly but are not cached. Fix with:

```bash
chown ispadmin:www-data /home/username/web/example.com/public_html
chmod g+ws /home/username/web/example.com/public_html
```

### Registries not generating

Registries only generate when a page is rendered  -  not on cached serves. If missing, delete the registry file and force a page render:

```bash
rm public_html/llms.txt
rm public_html/index.html
curl -s https://example.com/ > /dev/null
```
