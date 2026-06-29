---
title: What lazysite does
subtitle: The capabilities, by what you are trying to achieve. Each links to how it works.
register:
  - sitemap.xml
  - llms.txt
tt_page_var:
  feat: json:/data/features.json
---

[% feat.intro %]

<style>.feat-cat{margin:2rem 0}.feat-blurb{opacity:.75;margin:.2rem 0 1rem}.feat-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(260px,1fr));gap:16px}.feat-card{border:1px solid var(--theme-colours-border,#e3e3e3);border-radius:10px;padding:16px 18px;background:rgba(0,0,0,.015)}.feat-card h3{margin:0 0 6px;font-size:1.05rem}.feat-card p{margin:0 0 10px;font-size:.92rem;line-height:1.5}.feat-how{font-size:.85rem;font-weight:600;text-decoration:none}</style>

[% FOREACH cat IN feat.categories %]<section class="feat-cat"><h2>[% cat.name %]</h2><p class="feat-blurb">[% cat.blurb %]</p><div class="feat-grid">[% FOREACH f IN cat.features %]<div class="feat-card"><h3>[% f.title %]</h3><p>[% f.what %]</p>[% IF f.how_url %]<a class="feat-how" href="[% f.how_url %]">How it works: [% f.how_label %] &rarr;</a>[% END %]</div>[% END %]</div></section>
[% END %]
