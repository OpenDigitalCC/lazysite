---
title: Features
subtitle: All lazysite features by category.
register:
  - sitemap.xml
  - llms.txt
tt_page_var:
  authoring_features: scan:/docs/features/authoring/*.md sort=title asc
  config_features: scan:/docs/features/configuration/*.md sort=title asc
  dev_features: scan:/docs/features/development/*.md sort=title asc
---

<div class="features-layout">
<nav class="features-toc">
[% IF authoring_features.size %]
<h3>Authoring</h3>
<ul>
[% FOREACH f IN authoring_features %]
<li><a href="#[% f.url | replace('/', '-') | replace('^-', '') %]">[% f.title %]</a><br><small>[% f.subtitle %]</small></li>
[% END %]
</ul>
[% END %]
[% IF config_features.size %]
<h3>Configuration</h3>
<ul>
[% FOREACH f IN config_features %]
<li><a href="#[% f.url | replace('/', '-') | replace('^-', '') %]">[% f.title %]</a><br><small>[% f.subtitle %]</small></li>
[% END %]
</ul>
[% END %]
[% IF dev_features.size %]
<h3>Development</h3>
<ul>
[% FOREACH f IN dev_features %]
<li><a href="#[% f.url | replace('/', '-') | replace('^-', '') %]">[% f.title %]</a><br><small>[% f.subtitle %]</small></li>
[% END %]
</ul>
[% END %]
</nav>
<div class="features-content">

[% IF authoring_features.size %]
## Authoring

[% FOREACH feature IN authoring_features %]
<div class="feature-entry" id="[% feature.url | replace('/', '-') | replace('^-', '') %]">

::: include
[% feature.path %]
:::

</div>
[% END %]
[% END %]

[% IF config_features.size %]
## Configuration

[% FOREACH feature IN config_features %]
<div class="feature-entry" id="[% feature.url | replace('/', '-') | replace('^-', '') %]">

::: include
[% feature.path %]
:::

</div>
[% END %]
[% END %]

[% IF dev_features.size %]
## Development

[% FOREACH feature IN dev_features %]
<div class="feature-entry" id="[% feature.url | replace('/', '-') | replace('^-', '') %]">

::: include
[% feature.path %]
:::

</div>
[% END %]
[% END %]

</div>
</div>

<style>
.features-layout { display: flex; gap: 2rem; align-items: flex-start; }
.features-toc {
    position: sticky; top: 1rem;
    width: 220px; min-width: 220px;
    font-size: 0.8rem; line-height: 1.4;
    max-height: calc(100vh - 2rem); overflow-y: auto;
    padding-right: 1rem;
    border-right: 1px solid #eee;
}
.features-toc h3 {
    font-size: 0.75rem; text-transform: uppercase; letter-spacing: 0.05em;
    color: #888; margin: 1rem 0 0.3rem; padding: 0;
}
.features-toc ul { list-style: none; padding: 0; margin: 0 0 0.5rem; }
.features-toc li { margin: 0 0 0.4rem; }
.features-toc a { text-decoration: none; color: #0056b3; }
.features-toc a:hover { text-decoration: underline; }
.features-toc small { color: #888; font-size: 0.7rem; }
.features-content { flex: 1; min-width: 0; }
.feature-entry { border-bottom: 1px solid #eee; padding-bottom: 1.5rem; margin-bottom: 1.5rem; }
@media (max-width: 700px) {
    .features-layout { flex-direction: column; }
    .features-toc {
        position: static; width: 100%; min-width: 0;
        max-height: none; border-right: none;
        border-bottom: 1px solid #eee;
        padding: 0 0 1rem; margin-bottom: 1rem;
    }
}
</style>
