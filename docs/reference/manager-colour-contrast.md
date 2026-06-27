---
title: "Manager colour contrast standard"
subtitle: "WCAG targets for the manager token system, light and dark"
brand: plain
---

::: widebox
Colour contrast is a recurring readability concern in the manager, light and dark.
This sets the standard the `--mg-*` tokens are held to, records an audit of the main
tokens, and is the reference for picking any new colour.
:::

## The targets (WCAG 2.1)

Normal text
: contrast ratio **>= 4.5:1** against its background (AA). Aim for **>= 7:1** (AAA)
  where it is easy.

Large text (>= 18.66px, or >= 14px bold) and UI component boundaries
: **>= 3:1** (AA-large).

Deliberately de-emphasised text (placeholders, dimmed markers, timestamps)
: keep **>= 4.5:1** where it carries meaning; **>= 3:1** is the hard floor.

Use the relative-luminance formula (sRGB linearised, `0.2126R + 0.7152G + 0.0722B`)
and `(L_lighter + 0.05) / (L_darker + 0.05)`. The token values below were chosen by
computing this against the actual surface and background tokens, not by eye.

## Audit of the main text tokens

```datatable
columns: Token | Light (on surface) | Dark (on surface) | Notes
widths: 4cm | X | X | X
bold: 1
tone: medium
---
--mg-text | 17.5:1 AAA | 14.5:1 AAA | body text - both excellent
--mg-text-muted | 4.8:1 AA | 7.8:1 AAA | secondary text
--mg-text-light | 4.7:1 AA | 5.0:1 AA | faint tier - FIXED (was 2.5:1 light / 3:1 dark, both failing)
--mg-accent | 6.3:1 AA | 5.0:1 AA | links / primary
--mg-danger | 6.6:1 AA | 5.4:1 AA | errors
--mg-success | 5.7:1 AA | 7.4:1 AAA | confirmations
```

The audit found one real failure: `--mg-text-light` was `#a8a29e` in light mode
(2.5:1, below AA) and `#78716c` in dark (~3:1). These were the "feint, hard to read"
reports. Now `#79736d` (light, 4.7:1) and `#9a948c` (dark, 5.0:1). Everything else
already met AA or better.

## Editor syntax palette (dark)

The CodeMirror dark palette is tuned the same way against the editor surface
(`#2a2624`): headings, bold, links, strings, em, variables all clear **AAA (>= 7:1)**;
the deliberately dimmed comment/markers clear AA (~5.9:1). See the SM116 block in
`manager.css`.

## Applying this

- When adding or changing a `--mg-*` colour, compute its ratio against the surface it
  sits on, in **both** themes, and meet the target for its role.
- Prefer raising luminance and lowering saturation on dark - saturated red/orange read
  as "harsh/hard" even at nominal ratio; lighter, less-saturated variants read better.
- The dark accent/danger sit at ~5:1 (AA). If a future pass wants AAA across the
  board, lighten `--mg-accent` (#818cf8) and `--mg-danger` (#f97066) a little.
