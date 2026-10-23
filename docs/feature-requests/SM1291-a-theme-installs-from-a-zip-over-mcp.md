---
id: SM1291
title: "SM1291: a theme installs from a zip over MCP"
subtitle: "MCP had no way to install a theme with its fonts in one call: upload_file takes base64 per file, and the manager's zip upload had no MCP twin. install_theme is that twin, through the same function, and the function now also refuses what every other way into a theme refuses."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-22
raised-by: the lazysite.io site agent, inbox 2026-10-22-forms-validator-and-page-var-quotes.md (K-5)
area: mcp
status-note: "SHIPPED (PENDING) on n735: MCP install_theme (manage_themes) decodes the zip as upload_file does and calls Manager::Themes::action_theme_upload, so it goes through the archive checks 0.16.2 shipped as SM1303; records the install as the caller's for delete_theme, audits as theme-upload. t/unit/mcp/61."
---

# What happened

K-5, from the designer who built the `control` theme for lazysite.io: "upload_file
takes base64 in the call; five woff2 files were about 115 KB of text, so the
designer staged theme.json and main.css over MCP and handed the fonts over
separately. The control API has `theme-upload` for a zip; MCP has no
equivalent." (`theme-upload` is the manager UI's spelling, cookie-only; a token
client writes theme files over WebDAV, lint 87.)

# What shipped

- **MCP `install_theme`**, under `manage_themes`. It takes the zip as
  `content_base64` (decoded and refused exactly as `upload_file` decodes its
  bytes - the decoder is shared now) and an optional `filename`, and calls
  `Lazysite::Manager::Themes::action_theme_upload`, the function the manager's
  Upload Theme calls. So the checks are that function's: `theme.json` at the
  root, `layouts` present and every one installed, every entry checked for an
  absolute path or `..` before any is extracted, a copy under each layout with
  its `assets/` mirrored to `/lazysite-assets/LAYOUT/THEME/`, a name already
  installed taken beside it as `YYYYMMDD-name`. Nothing is activated; the
  result says to preview with `preview_page theme` (SM1290) and then
  `activate_theme`.
- **The audit row is theme-upload's**: the MCP trail labels it `theme-upload`,
  as the control API does, and names the theme it was installed as.
- **The install is recorded as the caller's**, as `create_theme` and
  `copy_theme` record theirs, so `delete_theme` - which over MCP reaches only a
  theme the caller made (SM262) - can take it away again.
- **Lint 23** records it as MCP-only with its reason: the twin, `theme-upload`,
  is cookie-only, and a token client has WebDAV. `describe_capabilities` lists
  it under `manage_themes`.

# What the shared function now refuses

Reusing the function for an agent's archive showed three gaps the other ways
into a theme do not have. They are closed in the function, so the manager's
Upload Theme gains them as well. That part shipped ahead of this branch, in the
0.16.2 security release as SM1303 (with t/integration/336); this branch carries
main's version of it, and `install_theme` reaches it through the function:

- **The site's upload limit** (`manager_upload_max_mb`, 10 MB by default), which
  file-upload and `upload_file` apply and this action did not. Refused as
  `too-large`, naming the limit.
- **A symbolic link.** Archive::Zip extracts a link member (what
  `zip --symlinks` writes) as a symbolic link, and `cp -r` copies it into the
  served asset mirror as one, so `/lazysite-assets/LAYOUT/THEME/x` became a link
  to anything the web server can read. Shown, not assumed: with the old code,
  t/integration/336's archive left `lazysite-assets/default/linky/passwd`
  pointing at `/etc/passwd`. Refused as `blocked` before anything is extracted.
- **A file type the web server runs** (the SEC-2026-07 list, `@DANGEROUS_EXT`:
  `.php`, `.cgi`, `.pl`, `.htaccess` and the rest), which WebDAV and
  `upload_file` refuse under a theme. The asset mirror is served from the
  docroot. Refused as `blocked`.

# Tests

- t/unit/mcp/61, over the MCP CGI: a zip with a stylesheet and a binary font
  installs, the font byte for byte in the served mirror, nothing activated; one
  theme-upload audit row names it; a second install of the name goes beside the
  first and leaves it untouched; `delete_theme` takes what the caller
  installed; refused, installing nothing: no `manage_themes`, bad base64, `..`,
  a symbolic link, a `.php` entry, no `layouts`, an uninstalled layout, an
  archive over a 1 MB limit. With Themes.pm as before, the symlink, `.php` and
  size refusals fail; with lazysite-mcp.pl as before, all five
  subtests fail. The tests mark their link members by hand in the zip's central
  directory, because Archive::Zip 1.68 writing a link member leaves a stray
  `GLOB(0x...)` link in the working directory.
- t/integration/336, the manager's own Upload Theme as a signed-in person: an
  ordinary theme installs; a symbolic link, a `.php` entry and an oversized
  archive are refused with nothing installed and nothing in the mirror. With
  Themes.pm as before, the three refusals fail, and the link is in the mirror.
