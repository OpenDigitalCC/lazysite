CANDIDATE - Social syndication (consumer + publisher)
======================================================

Status: candidate. Not scoped for implementation. Add
to the project's candidate list for future scoping.
Stuart will brief properly when ready to action.


Concept
-------

Two related features for lazysite to consume and
publish content via ActivityPub and AT Proto. Both
restricted to Slice 1 (publishing-format only; no
real federation, no inbox handling, no signed
outbound delivery from lazysite itself).

The goal is the POSSE pattern (Publish on your Own
Site, Syndicate Elsewhere): lazysite is the canonical
content store; social networks are syndication
targets and read sources.


Consumer side
-------------

Plugin (likely lazysite-social.pl) fetches public
feeds from configured sources, caches them, exposes
content as TT variables for inclusion in lazysite
pages.

Mechanics:

- ActivityPub: GET actor outbox (paginated
  OrderedCollection). No auth for public outboxes.
  Resolution via WebFinger for @user@server handles.

- AT Proto: GET AppView API
  (app.bsky.feed.getAuthorFeed) or PDS direct
  (com.atproto.repo.listRecords). DID resolution
  via HTTPS or DNS.

- Cache: leverage lazysite's existing TTL front-
  matter mechanism. Pages declaring feed deps
  regenerate on TTL expiry, picking up fresh
  remote content.

- Rendering: front-matter declares feeds with a TT
  variable name; templates iterate the populated
  variable. Example:

      feeds:
        - source: atproto
          handle: yoursite.example.com
          count: 10
          var: bsky_recent

- Filtering: by content type, date range, hashtag,
  length, media. Declarative in front-matter.

Scope: one plugin, two protocols, single
fetch/cache/render path with protocol-specific
marshalling.


Publisher side
--------------

Plugin syndicates lazysite articles to configured
social targets when articles are flagged for
publication.

Mechanics:

- Trigger: front-matter syndication block on
  articles. Status states: pending, published,
  failed.

- AT Proto: authenticated POST to PDS via
  com.atproto.repo.createRecord. App-password auth.
  Returns AT URI stored alongside the lazysite page.

- ActivityPub: emit JSON-LD at lazysite-served
  URLs (actor, outbox, individual posts as Articles
  via content negotiation). Federation handled by an
  external bridge service (Bridgy Fed or similar).
  Lazysite optionally pings the bridge on publish.

- Marshalling: title + summary + canonical URL.
  Summary fallback chain: front-matter `summary:` ->
  `subtitle:` -> first paragraph.

- Update/delete: configurable. On article update,
  optionally push update to syndicated copy. On
  article delete, optionally delete syndicated copy.

- Failure handling: status tracking in front-matter
  or sidecar file. Manual retry via manager UI. Cron-
  driven async retry.


Dependencies in lazysite core
------------------------------

These would need to land in core for the plugins to
work cleanly:

1. Front-matter mutation API (or sidecar JSON
   convention). Plugins need to record syndication
   status and remote URIs per page.

2. Cron hook convention. Plugins need to register
   periodic tasks (retry, refresh). Likely a
   tools/lazysite-cron.sh invoked by systemd timer
   or system cron, which scans plugins for
   --cron-tasks and runs them.

3. Secret storage convention. Plugins need
   credentials (AT Proto app passwords, ActivityPub
   bridge tokens) outside the git-tracked repo.
   Convention: file path in config, mode 600,
   manager UI accepts but doesn't display.

4. Public TT-variable injection. Consumer plugin
   needs to populate TT variables based on front-
   matter declarations. Generalisation of existing
   plugin-driven content patterns.


Manager UI additions
---------------------

For publisher:
- Syndication tab on article pages showing per-
  target status (pending, published, failed)
- Manual retry, manual update, manual delete buttons
- Per-page override of syndication targets

For consumer:
- Feed sources page (configure remote sources)
- Feed status (last fetch, cache age, errors)


Out of scope (deferred or rejected)
------------------------------------

- Slice 2 of either protocol (real federation,
  signed outbound delivery, inbox handling).
  Different architectural shape; doesn't fit
  lazysite's nature.
- Slice 3 (interactive Fediverse server). Out of
  scope entirely.
- Real-time delivery. Both consumer and publisher
  are eventually-consistent via cache TTLs and cron
  retries.
- Other social networks (Twitter/X, LinkedIn,
  etc.). Each would be additional target-specific
  marshalling; not in initial scope.


Adjacent opportunity: RSS/Atom
-------------------------------

Similar plugin shape applies to RSS/Atom consumption
(read other feeds, render in pages) and publication
(emit lazysite content as RSS feed). Costs little
extra alongside the social plugins. Consider
including in same syndication PD or as a separate
parallel candidate.


Estimated scope
---------------

Roughly:
- 1 SM: front-matter mutation or sidecar convention
- 1 SM: cron hook convention
- 1 SM: consumer plugin (both protocols)
- 1-2 SMs: publisher plugin (both protocols, with
  manager UI)
- Optional 1 SM: RSS/Atom consumer + publisher

Total 4-6 SMs. Spread over a few releases.


When to revisit
---------------

This earns priority when:
- Stuart's sites have a content cadence that warrants
  syndication (multiple posts per week, multiple
  audiences)
- AT Proto network or Fediverse usage becomes a
  practical channel for the content
- The cron hook is needed for other features and
  therefore not a single-purpose addition

Until then: keep filed, do not start.


For CC
------

Add to the project's tracked candidate list. No
action required now. When Stuart briefs an SM in
this area, refer back here for context.
