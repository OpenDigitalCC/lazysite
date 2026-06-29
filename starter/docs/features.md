---
title: Advanced authoring
subtitle: Every lazysite capability, by topic - the detailed how-to reference.
register:
  - sitemap.xml
  - llms.txt
tt_page_var:
  authoring_features: scan:/docs/features/authoring/*.md sort=title asc
  config_features: scan:/docs/features/configuration/*.md sort=title asc
  dev_features: scan:/docs/features/development/*.md sort=title asc
---

Every lazysite capability, grouped by topic. Open any page for the detail - each one links back here and on to the next, so you can step through a topic or read straight across.

<style>.feat-idx{margin:1.5rem 0}.feat-idx h2{margin:1.8rem 0 .5rem;font-size:1.2rem}.feat-idx ul{list-style:none;padding:0;margin:0}.feat-idx li{padding:.6rem 0;border-bottom:1px solid var(--theme-colours-border,#eee)}.feat-idx a{font-weight:600;text-decoration:none}.feat-idx small{display:block;opacity:.7;font-size:.85rem;margin-top:.15rem}</style>

<div class="feat-idx">
[% IF authoring_features.size %]<h2>Authoring</h2><ul>[% FOREACH f IN authoring_features %]<li><a href="[% f.url %]">[% f.title %]</a><small>[% f.subtitle %]</small></li>[% END %]</ul>[% END %]
[% IF config_features.size %]<h2>Configuration</h2><ul>[% FOREACH f IN config_features %]<li><a href="[% f.url %]">[% f.title %]</a><small>[% f.subtitle %]</small></li>[% END %]</ul>[% END %]
[% IF dev_features.size %]<h2>Development</h2><ul>[% FOREACH f IN dev_features %]<li><a href="[% f.url %]">[% f.title %]</a><small>[% f.subtitle %]</small></li>[% END %]</ul>[% END %]
</div>
