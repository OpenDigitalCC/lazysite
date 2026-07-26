---
title: "SM207 - ai-briefing-design-transfer.md (external-design -> theme/layout)"
subtitle: "The briefing set (authoring / layouts / publishing / configuration / building-sites) has no doc for the task shape the design-transfer work defined: bringing an EXTERNAL design (Figma, an existing site, a brand document) into the theme/layout system."
brand: plain
status: superseded
status-note: "SUPERSEDED by SM208 (2026-07-24), closed out 2026-07-26. The integrations briefing chose a scalable /docs/integrations/ namespace over a single flat ai-briefing-design-transfer.md; this doc's content (identity-as-tokens, role-based naming, rebuild-don't-copy, the what-NOT-to-ask list) is absorbed into SM208's figma.md translation section + the integrations index. Kept for history; implement via SM208, not this."
---

# SM207 - ai-briefing-design-transfer.md

## Why

The AI briefing set under `starter/docs/` (`ai-briefing-authoring`,
`-layouts`, `-publishing`, `-configuration`, `-building-sites`, ...) covers
authoring and building, but not the task this session's investigation defined:
transferring an EXTERNAL design - a Figma file, an existing site, a brand document
- into lazysite's theme/layout system. Twenty-plus sites have proven that Claude
translating a design SEMANTICALLY (rather than pixel-exporting) produces cleaner,
lighter, more maintainable sites; that method deserves a written briefing so it is
repeatable.

## What

One new doc, `starter/docs/ai-briefing-design-transfer.md`, registered into the
briefing set the same way its siblings are (sitemap + llms listing - follow the
`ai-briefing-layouts.md` precedent). Content to capture:

- The PRINCIPLE: identity transfers as tokens (palette, fonts, radius, content
  widths - near-mechanically); rhythm and scale are REBUILT in CSS, not copied.
  Pixel-reproduction is explicitly an anti-goal - link the monolith case study in
  `ai-briefing-building-sites.md`.
- The TARGET VOCABULARY: point at `theme_tokens` (SM204) / the `layout.json`
  `tokens` block (SM203) as the FIRST call of any transfer.
- The ROLE-BASED NAMING ask for design sources: colours named by role
  (`text`/`muted`, `brand`/`primary`) not by value (`grey-600`); the ~19-role
  colour vocabulary of the default layouts as the reference set; three font roles
  (body/heading/code); radius + measure + wrap.
- The WORKFLOW: `theme_tokens` -> map source tokens -> `create_theme` (SM205) ->
  preview -> adapt CSS -> activate. Copy-nearest-layout-and-adapt for structural
  changes, per the existing staging rules in `ai-briefing-layouts.md`.
- What NOT to ask a design team for: tokenised spacing scales, type scales,
  per-breakpoint values - lazysite has no theme slots for them and the CSS rebuild
  is where they land.

## Dependencies

- Depends on SM204/SM205 for the tool references. Either sequence it after they
  land, or ship it first describing the manual path (read_file + theme.json write +
  activate) and update the tool-call steps when SM204/SM205 land.

## House style

Authored via the pandoc-markdown skill per the house docs convention. Follow the
existing `ai-briefing-*` structure and front matter so it renders and registers
identically.

## Verification

- The doc appears in the site's doc index / llms listing beside the other
  briefings.
- The workflow section's tool calls match the shipped `theme_tokens` / `create_theme`
  schemas (or the manual path, if it ships ahead of them).
