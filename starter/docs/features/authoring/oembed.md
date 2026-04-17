---
title: oEmbed
subtitle: Embed video and audio from any oEmbed provider.
tags:
  - authoring
  - remote
---

## oEmbed

The `:::oembed` block embeds rich content from any oEmbed-compatible
provider. The provider's HTML embed code is fetched at render time and
baked into the cached page.

### Syntax

    ::: oembed
    https://www.youtube.com/watch?v=VIDEO_ID
    :::

### Supported providers

Built-in endpoint mappings for fast resolution:

- YouTube (`youtube.com/watch`, `youtu.be/`)
- Vimeo (`vimeo.com/`)
- Twitter/X (`twitter.com/`, `x.com/`)
- SoundCloud (`soundcloud.com/`)
- PeerTube (`/videos/watch/`, `/videos/embed/`) - via autodiscovery

Any other provider that supports oEmbed autodiscovery (a `<link>` tag
with `type="application/json+oembed"`) also works automatically.

### Example

    ---
    title: Conference Talks
    ---
    ::: oembed
    https://www.youtube.com/watch?v=dQw4w9WgXcQ
    :::

    ::: oembed
    https://vimeo.com/123456789
    :::

### Error handling

On success, the embed HTML is wrapped in `<div class="oembed">`.

On failure (no endpoint found, fetch failed, or missing `html` field
in the JSON response), the URL is rendered as a clickable link inside
`<div class="oembed oembed--failed">`. A warning is written to the
error log.

### Notes

- Only JSON format is requested (`format=json`)
- The provider's `html` field is inserted as-is - restrict the
  provider list to trusted hosts if this is a concern
- Embeds are fetched at render time and cached with the page
- PeerTube instances use autodiscovery since endpoints vary per instance
