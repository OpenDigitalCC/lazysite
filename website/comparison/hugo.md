---
title: lazysite vs Hugo
subtitle: Two lightweight, Markdown-first tools - one static, one dynamic.
register:
  - sitemap.xml
  - llms.txt
tt_page_var:
  comp: json:/data/comparison-hugo.json
---

Both lazysite and Hugo start from Markdown and value speed and simplicity. The difference is the build: Hugo compiles a static site you deploy, while lazysite renders on request and can also do dynamic work.

<style>.cmp-cards{display:grid;grid-template-columns:repeat(auto-fit,minmax(240px,1fr));gap:18px;margin:1.6rem 0 2rem}.cmp-card{border:1px solid var(--theme-colours-border,#e3e3e3);border-radius:10px;padding:18px 20px;background:rgba(0,0,0,.02)}.cmp-card h3{margin:0 0 6px;font-size:1.15rem}.cmp-card .cmp-tag{margin:0 0 10px;font-size:.92rem;opacity:.72}.cmp-card .cmp-best{margin:0;font-size:.95rem;line-height:1.5}.cmp-table{width:100%;border-collapse:collapse;margin:1rem 0 1.4rem;font-size:.93rem}.cmp-table th,.cmp-table td{text-align:left;vertical-align:top;padding:10px 12px;border-bottom:1px solid var(--theme-colours-border,#e3e3e3)}.cmp-table thead th{font-weight:700;border-bottom:2px solid var(--theme-colours-border,#cfcfcf)}.cmp-table tbody th{font-weight:600;width:28%}.cmp-table tbody tr:nth-child(odd){background:rgba(0,0,0,.025)}@media(max-width:640px){.cmp-table{font-size:.85rem}.cmp-table th,.cmp-table td{padding:8px}}</style>

<div class="cmp-cards">[% FOREACH s IN comp.systems %]<div class="cmp-card"><h3>[% s.name %]</h3><p class="cmp-tag">[% s.tagline %]</p><p class="cmp-best"><strong>Best suited for:</strong> [% s.best_for %]</p></div>[% END %]</div>

<table class="cmp-table"><thead><tr><th>Feature</th>[% FOREACH s IN comp.systems %]<th>[% s.name %]</th>[% END %]</tr></thead><tbody>[% FOREACH r IN comp.rows %]<tr><th>[% r.label %]</th>[% FOREACH s IN comp.systems %][% k = s.key %]<td>[% r.$k %]</td>[% END %]</tr>[% END %]</tbody></table>

**Choose lazysite** if you want live editing, AI-managed content, or server-side features like forms and paid pages. **Choose Hugo** for a large, purely static site with a developer build pipeline. See the [other comparisons](/comparison).
