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

## Authoring

[% FOREACH feature IN authoring_features %]
### [% feature.title %]

[% feature.subtitle %]

[Read more](#[% feature.title | lower | replace(' ', '-') %])

::: include
[% feature.path %]
:::

[% END %]

[% IF config_features.size %]
## Configuration

[% FOREACH feature IN config_features %]
### [% feature.title %]

[% feature.subtitle %]

::: include
[% feature.path %]
:::

[% END %]
[% END %]

[% IF dev_features.size %]
## Development

[% FOREACH feature IN dev_features %]
### [% feature.title %]

[% feature.subtitle %]

::: include
[% feature.path %]
:::

[% END %]
[% END %]
