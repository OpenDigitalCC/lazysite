---
title: How lazysite compares
subtitle: lazysite next to the tools you might use instead - honestly, by what each is best for.
register:
  - sitemap.xml
  - llms.txt
tt_page_var:
  idx: json:/data/comparisons.json
---

[% idx.intro %]

<style>.cmp-index{width:100%;border-collapse:collapse;margin:1.4rem 0;font-size:.95rem}.cmp-index th,.cmp-index td{text-align:left;vertical-align:top;padding:12px 14px;border-bottom:1px solid var(--theme-colours-border,#e3e3e3)}.cmp-index thead th{font-weight:700;border-bottom:2px solid var(--theme-colours-border,#cfcfcf)}.cmp-index td:first-child{font-weight:600;white-space:nowrap}.cmp-index a{font-weight:600;text-decoration:none}</style>

<table class="cmp-index"><thead><tr><th>Compared with</th><th>What it is</th><th></th></tr></thead><tbody>[% FOREACH c IN idx.comparisons %]<tr><td>[% c.subject %]</td><td>[% c.what %]</td><td><a href="[% c.url %]">lazysite vs [% c.subject %] &rarr;</a></td></tr>[% END %]</tbody></table>

This is not a contest - each tool is the right choice for different needs. The pages above describe, factually, what each does well.
