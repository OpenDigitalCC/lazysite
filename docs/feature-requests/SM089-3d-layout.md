---
title: F-3d-layout — 3D-rendered site layout
subtitle: Feature request, research-backed proposal
status: candidate
priority: medium
audience: developers, theme authors, operators
---

# F-3d-layout — A 3D-rendered site layout for lazysite

A feature request for a new layout category in lazysite-layouts: sites whose
primary rendering is a 3D scene navigated in the browser, not a stack of
HTML blocks. Content from the docroot's markdown maps into the 3D space;
themes set the environment.

This is a research-backed proposal — not a commitment to ship — to be filed
as a candidate alongside the others (social syndication, MCP connector,
chrome export). It earns priority when there's a real site that wants it,
or when lazysite needs a flagship demonstration of what its layout system
can do.

## Why this fits lazysite specifically

Most CMSs assume a 2D HTML page model. When operators want anything else
they leave the CMS, build a bespoke site, and lose the manager UI, the
publishing flow, the auth model, and everything else the CMS provided.

Lazysite's D013 split — layouts and themes as independent, swappable units
with a clean install path — means **a layout can change the rendering
substrate entirely** without touching the engine. The content stays in
markdown. The author keeps writing posts and editing in the manager UI.
The layout decides how those posts appear: as HTML, as 3D objects in a
gallery, as text floating in space, as anything else. This isn't true of
WordPress themes, of Jekyll templates, of most static-site generators. A
WordPress theme can dress up HTML; it can't replace HTML with WebGL. A
lazysite layout can.

The second-order consequence is **the layout system can host an alternative
manager**. Today's manager is a set of markdown pages with inline HTML
forms, rendered by lazysite itself. A different layout could provide a
different manager experience — visual editor, drag-and-drop, WYSIWYG —
served from the same backend, talking to the same control API. F0018
(lazysite Studio) explores this; the 3D layout is a parallel proof that
the substrate is genuinely pluggable.

Third: lazysite's recent MCP integration means **authoring tedium can be
delegated to AI partners**. The hardest authoring problem in a 3D layout
is "where does this content go in space" — and that's a categorisation
problem an AI partner is well suited to handle. An author writes a post;
the MCP connector decides which room it belongs in, assigns a wall slot,
positions related items nearby, regenerates the spatial registry. The
content stays in markdown; the spatial metadata lives in front-matter or
sidecars; the AI does the layout work that would otherwise be tedious for
a human.

These three properties — pluggable rendering substrate, alternative
manager surface, AI-assistable spatial layout — make lazysite a genuinely
good host for this kind of experiment. The feature must earn its place by
being useful, not just demonstrate that it's possible.

## Background research

### The library landscape (2026)

WebGL is the underlying browser API; nobody writes WebGL directly for site
work. The libraries layered on top:

**Three.js** — the dominant mid-level library. About 168KB minified and
gzipped[^1]. Imperative API: build the scene with code, manage every
update yourself. Around 3.5M weekly downloads on npm. Largest community,
most tutorials, most third-party libraries. Used by most of the
award-winning WebGL sites on awwwards.com. Best when you want full
control and don't mind writing more code.

**Babylon.js** — Microsoft-backed alternative. Larger (about 1.4MB
minified+gzipped, though modular)[^1]. Batteries-included: physics
engine, animation system, visual editor, asset manager, XR support built
in. Around 400K weekly downloads. Better for production teams that want
opinionated infrastructure and predictable scaling. Probably overkill for
a lazysite layout where the goal is page-shaped content in 3D, not games.

**A-Frame** — built on top of Three.js. Uses HTML markup directly: you
write `<a-scene><a-box position="0 1 -3"></a-box></a-scene>` and it
renders[^2]. Maintained by Supermedium (Diego Marcos, Kevin Ngo) and
Google (Don McCurdy); originally from Mozilla[^3]. About 17,560 GitHub
stars, MIT licence, current release 1.7.1[^4]. Used in production by
Google, Disney, Samsung, Toyota, Ford, Chevrolet, Amnesty International,
CERN, NPR, Al Jazeera, Washington Post, NASA[^2]. Supports Meta Quest,
Apple Vision Pro, PICO, Lynx-R1, Valve Index for WebXR. Built-in visual
inspector via ctrl+alt+i.

**React Three Fiber** — Three.js as React components. Excellent for SPA
apps; wrong fit for lazysite (would force importing React for what is
otherwise a static-site renderer).

**PlayCanvas** — engine-style with a hosted editor at playcanvas.com.
Engine itself is MIT. More opinionated than Three.js, less mature
ecosystem than Babylon. Niche fit.

**model-viewer** — Google's web component for displaying a single 3D
model. Narrow scope (one glTF in a box, rotateable, no scene). Useful as
a complement to a 2D layout (a product page with a rotatable model), not
as the basis for a 3D layout.

**Spline** — proprietary design tool with a runtime player. Closed
source, third-party dependency. Doesn't fit a project that ships under
MIT with a strict SBOM gate and CRA-Article-13 manufacturer-duty posture
(see POLICY.md).

**Needle Engine** — Unity-to-web bridge. Overkill and licensing complex.

### Why A-Frame is the right fit for lazysite

A-Frame wins on five criteria:

1. **HTML composes naturally with TT templates.** Lazysite's layouts are
   `layout.tt` files emitting HTML. A-Frame's scene description IS HTML.
   A TT FOREACH over content can directly emit `<a-image>`, `<a-text>`,
   `<a-box>` entities. Three.js would require a templating layer
   producing JS, which lazysite doesn't have. The match is structural.

2. **No build step required.** A-Frame loads from a `<script>` tag. No
   webpack, no rollup, no bundling. Lazysite is fundamentally a no-build
   system — the markdown lands on disk, the processor renders, the page
   appears. A library that requires a build step would break that
   property. A-Frame doesn't.

3. **Declarative authoring.** Authors and theme designers who don't know
   3D can read A-Frame markup and understand it. `<a-box color="red"
   position="0 1 -3">` is self-documenting. Three.js's imperative API is
   not.

4. **WebXR for free.** If the user has a headset, the scene works in VR
   without code changes. The current XR landscape is shifting — 44% of
   industry coverage in 2026 is on AR and smart glasses rather than
   VR[^5] — but WebXR support means the layout doesn't go obsolete as
   hardware changes. Supports Meta Quest, Apple Vision Pro, Samsung
   Galaxy XR, PICO, etc.

5. **Visual inspector built in.** Ctrl+alt+i opens an editor inside the
   running scene. Theme authors can position elements live, then export
   the result. No separate tooling needed.

The cost is bundle size. A-Frame plus its environment component plus a
few community components is about 1MB gzipped. That's heavy compared to
a normal lazysite page, but light compared to the 26MB-down-to-560KB
struggles documented for custom Three.js builds[^6]. For a layout
explicitly chosen for 3D, the cost is acceptable.

### Scenery options — beyond rooms

The ClementCariou virtual-art-gallery proof[^7] uses a corridor model:
walls, paintings hanging on walls, first-person navigation through
rooms. That's one shape. It's not the only shape, and for many sites
it's the wrong shape.

A-Frame's environment component[^8] ships with **15 presets** covering
most realistic non-room scenery:

- **egypt** — desert with pyramids, hot sky
- **checkerboard** — abstract reference plane
- **forest** — outdoor with trees
- **goaland** — open landscape with hills
- **yavapai** — canyon walls
- **goldmine** — underground rocky environment
- **threetowers** — vertical landmarks on plain
- **poison** — toxic-looking ground
- **arches** — natural sandstone formations
- **tron** — neon grid (the obvious cyberpunk reference)
- **japan** — pagoda landscape
- **dream** — surreal floating geometry
- **volcano** — fiery scene
- **starry** — night sky over plain
- **osiris** — alien

Each preset accepts overrides — `groundColor`, `skyColor`, `lightPosition`,
`fog`, `dressing` (the decorative props scattered around). The component
auto-generates lighting that matches the chosen environment.

For lazysite's purposes, this means a theme author doesn't start by
modelling a room in Blender. They pick a preset, set a few overrides,
and ship. The environment IS the theme.

Beyond presets, A-Frame supports:

- **Skyboxes** — `<a-sky>` with a 360° equirectangular image. Anything
  from sunset to deep space to abstract painted environments.
- **Atmospheric sky** — procedural sky based on sun position; lowering
  the sun toward the horizon turns the scene into sunset, then night,
  automatically.
- **Particle systems** — community components for stars, snow, dust,
  rain.
- **Custom geometry** — primitives plus glTF model loading. A theme can
  ship a custom architecture (cathedral, spaceship, museum) as a glTF
  file.

So the room model isn't required. A site could be a starfield with
content floating as text panels. A canyon with posts carved into cliff
faces. A neon city with billboards. A forest clearing with each post on
a tree. A nebula with floating cards. The constraints are aesthetic, not
technical.

### Navigation models

The virtual-art-gallery uses first-person WASD + mouse navigation. That's
one approach, well-suited to room-like scenery. Other options:

**Free-fly** — six degrees of freedom, like a space sim. Good for
starfield/nebula/free-space scenes where there's no ground. A-Frame
supports this via the `wasd-controls` component with `fly: true`.

**Orbit** — camera circles a central point; mouse drags rotate. Best for
single-focus scenes (one large object, planet, sculpture in a void). The
A-Frame community has `orbit-controls` components for this.

**Rail/path** — the camera follows a predetermined route; user controls
pace. Good for narrative or guided-tour sites. Implementable via A-Frame
animations or community path-follower components.

**Teleport** — user clicks a destination; camera jumps. Good for VR
(reduces motion sickness) and for clearly-structured navigation. A-Frame
ships with teleport components.

**Hybrid** — typical for VR sites. WASD on desktop, teleport in VR.
A-Frame handles this automatically via WebXR controller detection.

Choice of navigation should be a layout-level decision (the layout
ships with one), but possibly with theme-level override (themes for the
same layout might prefer different navigation).

### Reception of 3D websites — what users actually say

I looked for honest feedback on the reception of 3D sites in 2025-2026.
The picture is mixed and instructive.

Positive findings:

- Cappasity reports 3D elements can increase visitor time on page by up
  to 6x[^9]. (Self-interested source, but corroborated elsewhere in
  industry articles.)
- 3D sites win awwwards regularly; the awwwards WebGL collection
  represents the visual high-water mark of web design[^10].
- E-commerce sites using 3D product viewers report higher conversion and
  lower return rates — the canonical example being "see the sofa in your
  living room"[^11].

Negative findings (the more useful ones):

- "A lot of viral 3D websites are wow demos. They look beautiful. They
  convert nothing. They lag on mobile."[^12]
- "Stability, performance, and maintainability are [the hard parts].
  Most 3D web projects fail not because the idea is weak, but because
  the build ignores how browsers, devices, and users actually
  behave."[^13]
- "If 3D cannot work on a phone, design a clean fallback. Do not just
  hope."[^12]
- Common usability failures cited: hijacking the scroll, freezing the
  page, rewiring the back button. "Cool for an art installation. Bad for
  a business."[^12]
- Accessibility is a persistent weakness. Screen readers can't read text
  baked into 3D models. Keyboard-only navigation in 3D is rare.
  Photosensitive users can be harmed by certain animations[^14].

The consistent advice from people who build these professionally is:

1. The 3D must do real work — explain something, make something feel
   real, tell a story — not just decorate.
2. Mobile must be a first-class target, not an afterthought.
3. There must be a 2D fallback for users who can't or don't want the 3D.
4. Performance work (asset optimisation, lazy loading, GPU detection) is
   the unglamorous core of any 3D site that ships successfully.

A lazysite 3D layout that's not honest about all four will produce sites
that look great in a demo and frustrate real visitors.

### Lessons from the virtual-art-gallery proof

ClementCariou's gallery is small but instructive. Key choices:

- **Procedural architecture.** The corridor layout is generated from a
  10km-long 6th-order Hilbert curve — a space-filling fractal. The
  developer didn't hand-design rooms; the gallery generates them.
  Paintings populate the walls automatically as the user walks past
  unrendered sections[^15].

- **Content from a public API.** The paintings come from the Art
  Institute of Chicago's open API. The gallery is content-agnostic — it
  could just as well render images from a lazysite docroot.

- **Uses REGL, not Three.js.** REGL is a lower-level WebGL wrapper with
  a functional API. The developer's other projects suggest a preference
  for lightweight tooling over framework weight. Worth noting because it
  shows the project is *not* using A-Frame or Babylon.js — proof you can
  build a working 3D gallery with relatively little machinery, though at
  the cost of an HTML/template-friendly authoring surface.

- **Open-source, MIT-style.** 220 stars, 87 forks. Several other people
  have forked it to add their own art (ehsanpo, SanskrutiMhatre, etc.).
  Suggests a real if small audience for this kind of thing.

- **Limited interaction.** Walk and look. No clicking on paintings, no
  navigation between rooms, no metadata overlay. It's an exploration
  experience, not a navigation experience. A lazysite layout would need
  to add interactivity — clicking content to read, navigation between
  spaces, search.

### Other comparable sites worth studying

I'll be honest about what I can verify here. Many "3D websites" cited in
articles are decorative — a hero animation, a scroll-tracked model, not
a primary 3D rendering. The truly site-as-3D-space examples are rarer.

- **awwwards WebGL collection**[^10] — curated list of winning sites.
  Most are decorative 3D rather than substrate 3D, but the curation is
  high quality and surfaces what professional designers consider state
  of the art.
- **A-Frame examples gallery**[^16] — official; mostly small demos
  rather than full sites, but useful for studying patterns.
- **rahel-yab's Virtual-art-gallery**[^17] — different developer, also
  Three.js-based, multi-room layout, first-person navigation,
  procedural-textured marble floors, interactive animations. Slightly
  more polished than ClementCariou's. Worth playing with to see how the
  pattern can be developed.

Outside lazysite's frame: museum sites (Smithsonian's "Beyond the Walls"
VR exhibition, the British Museum's various 3D collection viewers),
educational sites (NASA Eyes for solar system visualisation), and
conference platforms (Mozilla Hubs, FRAME) all use 3D space as their
primary surface. None of them are CMS-driven; they're bespoke builds.
That's the gap a lazysite 3D layout would fill — making the substrate
plug-and-play for content already managed in lazysite.

## Proposal — what a lazysite 3D layout would actually be

Filed as a feature request for the lazysite-layouts repo, depending on
small enabling work in lazysite core.

### Scope decisions

**Library: A-Frame.** Reasons above. Bundled with the layout, version
pinned, served from lazysite-assets.

**Default shape: Shape A (fully 3D site).** Less common but more
interesting. Content from the docroot maps into the 3D scene; the
scene is the site. A Shape B variant (3D hero + regular content below)
or Shape D (3D fenced block within a normal page) could ship as later
sibling layouts; this proposal is for the substrate-3D case.

**First theme: starry/space.** Not a gallery. Reasons:

- The gallery model is well-explored; doing one well requires architectural
  modelling skills that aren't lazysite's strength.
- A starfield/space theme uses A-Frame's built-in environment + a
  particle component; the layout author writes the content placement,
  not the architecture.
- Space is universally legible — every culture understands "stars,
  void, floating things". Rooms are culturally specific.
- It separates lazysite's offering from the existing virtual-art-gallery
  ecosystem; doesn't compete with what's already out there.
- Content as "floating cards in space" maps naturally to how posts work
  in a normal blog or knowledge base. Each post is a card; navigation is
  flying between them.

Subsequent themes: gallery (the room model, for users who do want it),
canyon (cliff-face content), forest (clearing with content on trees),
abstract (geometric void). Each is a separate theme using the same
layout.

**Navigation: WASD + mouse on desktop; teleport in VR; orbit fallback
on mobile.** The mobile experience is the hard problem; on a phone
touchscreen, free-look navigation is awkward. Orbit-around-a-fixed-point
gives mobile users a useful interaction without requiring them to
master 3D controls.

**Content mapping rules.** Posts in the docroot become 3D entities. The
mapping rules go in `layout.json`:

- Default: chronological. Newest post nearest the spawn point; older
  posts further out in a spiral.
- Front-matter override: `position: 12 4 -30` places that post
  explicitly.
- Front-matter `cluster: projects` groups posts in a named region.
- The layout exposes a TT variable `spatial_index` populated by the
  processor; theme template iterates and places content.

**Fallback content.** Every page renders normal HTML to `<noscript>` and
also under `?fallback=1`. Search engines, screen readers, low-power
devices, users who don't want 3D — all get the standard markdown
rendering. The 3D is enhancement; the content is canonical.

**Asset handling.** glTF/glb models (3D objects in scene), textures
(JPG/PNG), audio (MP3/OGG ambient). Managed via the existing manager UI
upload flow; the layout declares which file types it expects and where.

### Required lazysite core additions

For the 3D layout to work cleanly:

1. **Asset type allowlist extensions.** Currently lazysite handles
   markdown, HTML, images, PDFs. Add explicit MIME types for glTF/glb,
   audio formats, and any other 3D-relevant types. Small Apache config
   plus manager UI extension.

2. **Spatial-registry generation.** A new registry template
   (`registries/spatial.json.tt` or similar) emits content positions
   based on front-matter and rules. Layout consumes this. Parallel to
   the existing sitemap registry.

3. **Layout-controlled content negotiation.** The layout decides whether
   a request gets 3D HTML or 2D fallback HTML, based on the `?fallback=1`
   query param or the Accept header. Currently the processor's content
   negotiation is theme-agnostic; the layout would need to inject the
   decision.

4. **Asset size limits per layout.** A 3D layout legitimately uploads
   much larger files than a text layout. The layout's `layout.json`
   should be able to declare its expected file size limits, overriding
   the site-wide defaults.

None of these are large additions. Together they enable the 3D layout
without baking 3D-specific knowledge into the core processor.

### Required theme schema additions

A 3D-aware theme declares (in `theme.json`):

- Environment preset name or skybox URL
- Lighting (ambient colour, intensity; primary light direction and
  colour)
- Ground (colour, texture, or "none")
- Spatial scale (meters per unit; affects how far apart content appears)
- Navigation mode (walk / fly / orbit / teleport)
- Audio (optional ambient track URL, gain)
- Content presentation (text on plates, text in space, images framed,
  images unframed, etc.)

This is a separate schema from the current CSS-token theme. The 3D
layout's themes use this 3D schema; the 2D layouts' themes use the CSS
schema. Layouts declare which schema their themes follow.

### AI-partner integration

The hardest authoring task is "where does this content go in 3D space".
This is exactly the kind of task an MCP-connected AI partner handles
well. Workflow:

- Author creates a new post via the manager UI or WebDAV.
- The MCP connector watches the docroot for new posts (or the partner
  is invoked explicitly).
- The partner reads the post, the site's spatial registry, related
  posts, and the layout's mapping rules.
- The partner proposes a position and writes it to the post's
  front-matter.
- Operator approves or adjusts.

This treats spatial placement as content metadata, generated by the
same AI partner that handles the rest of authoring. Aligns with
lazysite's "AI assists tedium" positioning.

### Manager UI implications

The current manager assumes 2D. A 3D layout needs at minimum:

- A spatial-position field on the page edit form
- A "preview in scene" link
- An optional in-manager 3D preview (using A-Frame's inspector embedded
  in the manager) — nice-to-have, not required for v1

The spatial-position field could surface only when the active layout
declares it; this is already the pattern for layout-specific config.

### Accessibility commitments

Non-negotiable:

- Fallback 2D rendering always available via `?fallback=1` and
  `<noscript>`. Same content, no functionality loss.
- No content trapped exclusively in 3D — every paragraph readable
  outside the 3D scene.
- Keyboard navigation works in the 3D scene where possible (Tab cycles
  through content items; Enter activates).
- No flashing animations above WCAG thresholds.
- All animations respect `prefers-reduced-motion`.
- Screen-reader-only summary of scene content (which rooms exist, how
  to navigate).
- Mobile-friendly orbit navigation as default on touchscreens.

### Performance commitments

- Total scene load ≤ 5MB on first visit (compressed). Subsequent visits
  use browser cache.
- Lazy load content as the user navigates; not everything in memory at
  once.
- Texture compression (basisu or similar) for any non-trivial images.
- Frame rate target: 60fps desktop, 30fps mobile. Auto-degrade quality
  on low-spec devices.
- glTF models in the layout itself: keep under 1MB total. Content
  uploaded by operators is their responsibility but the manager should
  warn on large uploads.

### What this proposal is not

- Not a games engine. Lazysite isn't trying to host Half-Life. The 3D
  is for content presentation, not interaction-heavy experiences.
- Not VR-first. WebXR works because A-Frame gives it for free, but the
  default experience is desktop browser.
- Not the only layout. Most lazysite sites should stay 2D. This is a
  layout for specific use cases.
- Not a substitute for accessibility. The 2D fallback is canonical.

## Estimated scope

If actioned, breaks down as:

| SM | Scope | Repo |
|---|---|---|
| Core 1 | Asset type allowlist + manager upload support | lazysite |
| Core 2 | Spatial registry generation | lazysite |
| Core 3 | Layout-controlled content negotiation hook | lazysite |
| Core 4 | Per-layout asset size limit overrides | lazysite |
| Layout 1 | Base 3D layout (A-Frame, content mapping, fallback) | lazysite-layouts |
| Theme 1 | Starfield theme | lazysite-layouts |
| Theme 2 | Gallery theme | lazysite-layouts |
| Docs | Theme-author briefing for the 3D layout schema | lazysite |

Realistically 8-12 SMs over 4-6 releases of each repo. Several weeks of
focused work even with CC handling implementation.

Not urgent. Not blocking. Files as a candidate; revisits when a real
site wants it or when lazysite needs a flagship demonstration.

## Why file this now

Three reasons to record this properly rather than leave it as a thought:

1. **It validates the D013 layout architecture.** If we can plan a
   working 3D layout against the existing architecture, the architecture
   is genuinely substrate-agnostic. That's worth knowing.

2. **It informs the MCP connector design.** The spatial-placement-as-AI-task
   workflow gives the MCP connector a real, valuable use case that isn't
   just CRUD on pages. Worth scoping the connector with that in mind.

3. **It sets a marker for ambition.** Lazysite's core values (make it
   easy to do what you want; respect content as primary; AI assists
   tedium) need ambitious demonstrations as well as conservative ones.
   This is a candidate for the ambitious end.

## Open questions for Stuart

1. Is there a site planned that would actually want this, or is it for
   demonstrative purposes? Answer affects priority.
2. Should this go in the same lazysite-layouts repo or a separate
   "experimental-layouts" repo? D013 doesn't currently distinguish, but
   a 3D layout has very different dependencies (A-Frame bundle) than a
   normal HTML layout.
3. Is operator audience for 3D layouts expected to be:
   - artists/galleries (the obvious case)?
   - product showcases?
   - educational sites?
   - something else?
4. The MCP connector for lazysite is itself a candidate. Should F-3d-layout
   depend on it, or be designed to work without it (with manual spatial
   placement as fallback)?

---

[^1]: pkgpulse.com bundle size measurements; bundlephobia data, 2026.
[^2]: aframe.io official documentation and aframevr/aframe README on
      GitHub, current at 2026.
[^3]: en.wikipedia.org/wiki/A-Frame_(virtual_reality_framework), updated
      January 2026.
[^4]: github.com/aframevr/aframe; 17,560 stars, MIT licence, release
      1.7.1, last commit June 15 2026.
[^5]: vr.org State of VR & AR 2026 data study; 130-story analysis showing
      44% of VR coverage shifted to AR/smart glasses.
[^6]: echobind.com case study, "26MB down to 560KB", documents the real
      effort of asset optimisation for production 3D web work.
[^7]: github.com/ClementCariou/virtual-art-gallery; REGL-based, 220
      stars, 87 forks. Uses 10km Hilbert curve for procedural
      architecture; Art Institute of Chicago API for content.
[^8]: github.com/supermedium/aframe-environment-component; documents
      15 preset environments and the override parameters.
[^9]: Cappasity study cited in framer.com/blog/3d-website-examples,
      March 2026.
[^10]: awwwards.com/websites/webgl/ — Awwwards' WebGL collection,
       curated list of award-winning sites.
[^11]: noomoagency.com case studies on e-commerce 3D conversion.
[^12]: wixfresh.com "10 Best 3D Websites Examples of 2026 Ranked and
       Reviewed", honest assessment of trade-offs.
[^13]: Medium article by Uday Mayank Dhodi, "3D Websites: Challenges,
       Trade-offs, and a Practical Build Model", February 2026.
[^14]: aleaitsolutions.com analysis of 3D web design accessibility
       challenges, including ARIA labels and keyboard navigation.
[^15]: Hilbert curve architecture documented in the ClementCariou
       virtual-art-gallery README.
[^16]: aframe.io/examples/ — official A-Frame examples.
[^17]: github.com/rahel-yab/Virtual-art-gallery — alternative
       Three.js-based virtual gallery with first-person navigation.
