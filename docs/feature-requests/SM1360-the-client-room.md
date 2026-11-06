---
id: SM1360
title: "SM1360: the client room: one thread between a site's owner and its agent"
subtitle: "Questions and answers about a site's changes happen on the site, signed in, instead of out of band by email. The owner gets an email only to say there is a reply."
brand: plain
standard-margins: true
status: candidate
raised: 2026-11-06
raised-by: "release manager (SM1350 discussion)"
area: content
status-note: "Filed 2026-11-06 under SM1350. Check the existing briefs tools and form submissions before building anew."
---

# Proposed

- **One thread per site:** private to the site's owners, the service team and the site's agents.
  - Each message carries its author, time and text.
  - A message may attach a preview link (SM1354) or a photo request (SM1359).
- **Owners:** read and post in the manager and the simple manager (SM1353).
- **Agents:** `list_room_messages` and `post_room_message`. The existing briefs tools (`list_briefs`, `read_brief`, `append_brief`) may already be most of this; extend those before adding new ones.
- **Notice:** new messages are sent by email notice through the site's notification sender. The email says only that there is a message, never its contents, and links to the room.
- **Retention:** kept as site records. They are not content and never served publicly.
- **Paging** from the start (SM1361).

# Questions for ruling

1. Should the room also be where the agent's own questions about a brief go during site creation?
