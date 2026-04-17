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

[% IF authoring_features.size %]
## Authoring

[% FOREACH feature IN authoring_features %]
<div class="feature-entry">

::: include
[% feature.path %]
:::

</div>
[% END %]
[% END %]

[% IF config_features.size %]
## Configuration

[% FOREACH feature IN config_features %]
<div class="feature-entry">

::: include
[% feature.path %]
:::

</div>
[% END %]
[% END %]

[% IF dev_features.size %]
## Development

[% FOREACH feature IN dev_features %]
<div class="feature-entry">

::: include
[% feature.path %]
:::

</div>
[% END %]
[% END %]
