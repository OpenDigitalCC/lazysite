---
id: SM776
title: "SM776: write_file warns about pages only"
subtitle: "Reported from a site on 0.12.1: MCP write_file of a stylesheet under a theme's assets/ answered with a page-shaped warning, 'page has no title in front matter'. Harmless, and exactly the kind of warning that teaches an agent to ignore this tool's warnings."
brand: plain
standard-margins: true
status: shipped
status-note: "BUILT 2026-09-08 on claude/sm776-write-file-warns-about-pages-only. write_file runs the page validator only for a .md path; a theme.json keeps its own validator; every other file gets no page warnings. t/unit/mcp/14 writes a stylesheet and asserts no no-title warning."
---

# What the field saw

```json
"warnings":[{"kind":"no-title","message":"page has no title in front matter"}]
```

on `write_file` of `.../themes/familyhq/assets/probe-8sep.css`.

# What was true

`write_file` validated a `theme.json` with the theme validator and everything
else with the page validator - a `.css`, a `.js`, a `.txt` alike.

# What is built

The page validator runs for a `.md` path only. Files that are not pages get
no page warnings; a theme.json keeps its own. The test writes a stylesheet
under a non-active theme and asserts the write succeeds without `no-title`.

# Filed with it, answered without a change

The same report's main finding - the active theme accepting writes over MCP
while WebDAV refused them - is SM749, shipped in 0.13.1: the theme being
served is read-only on every surface, and the refusal names the workflow
(copy, edit the copy, activate). The site that reported it runs 0.12.1. The
report's question - how a theme's source reaches its `/lazysite-assets/`
mirror - is answered in the layouts briefing since the same release: the
mirror is rebuilt on every activation.
