---
id: SM1303
title: "SM1303: a theme archive cannot plant a link in the served asset mirror"
subtitle: "The manager's theme upload copied a zip's symbolic link into /lazysite-assets/, so a public URL served any file the web server can read - the session-signing secret among them. Every entry is now checked before any is extracted, and a link, a file type the web server runs or an oversized archive refuses the whole archive."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-23
raised-by: "found while building SM1291 (MCP install_theme) on n735; ruling 41 as revised and 41b (2026-10-23): a security release, 0.16.2, cut from main"
area: security
status-note: "SHIPPED (PENDING) on n738: Manager::Themes::action_theme_upload applies the site's upload limit and refuses a symbolic link and a server-run file type before extracting anything. The Themes.pm part of n735's 306e5c778, without the MCP tool; the register entry from eb634ffa0, re-keyed. t/integration/336."
---

# What happened

Building MCP `install_theme` (SM1291, on n735) reused the manager's Upload Theme
(`theme-upload`, `Lazysite::Manager::Themes::action_theme_upload`) and showed three
gaps the other ways into a theme do not have. One is a vulnerability: Archive::Zip
extracts a symbolic-link member (what `zip --symlinks` writes) as a link, and `cp -r`
copies it into the served asset mirror as one. So `/lazysite-assets/LAYOUT/THEME/x`
became a public URL for anything the web server's user can read - including
`lazysite/auth/.secret`, the secret session cookies are signed with. A holder of
`manage_themes` could read it and mint an operator's session.

Every release from 0.1.0 to 0.16.1 is affected. Ruling 41 as revised makes the fix
a security release: this branch carries the archive checks and the planted-link
warning (SM1304) alone, cut from main as 0.16.2 and marked security-critical
(SM1305); the MCP tool stays in the batch it was built in.

# What shipped

`action_theme_upload` checks every entry before it extracts any, and refuses the
whole archive, with nothing installed and nothing in the mirror, for:

- **A symbolic link** (`blocked`, naming the entry).
- **A file type the web server runs** (the SEC-2026-07 list, `@DANGEROUS_EXT`:
  `.php`, `.cgi`, `.pl`, `.htaccess` and the rest), which WebDAV and `upload_file`
  already refuse under a theme (`blocked`).
- **An archive over the site's upload limit** (`manager_upload_max_mb`, 10 MB by
  default), which file-upload and `upload_file` apply and this action did not
  (`too-large`, naming the limit).

The absolute-path and `..` checks were already there. The themes page in the
manual says what the upload refuses. `docs/SECURITY.md` gains a STRIDE row and a
dated register entry, drafted for the release manager's confirmation.

A link planted before 0.16.2 stays until it is removed: SM1304 makes
`lazysite check` name it.

# Tests

- t/integration/336, the manager's own Upload Theme as a signed-in person: an
  ordinary theme installs; a symbolic link, a `.php` entry and an oversized archive
  are refused with nothing installed and nothing in the mirror. With Themes.pm as on
  main, the three refusals fail, and the link is in the mirror. The test marks its
  link members by hand in the zip's central directory, because Archive::Zip 1.68
  writing a link member leaves a stray `GLOB(0x...)` link in the working directory.
