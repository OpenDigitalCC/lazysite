---
id: SM1359
title: "SM1359: photo updates: a transient intake, read by a connected agent, proposed as a copy"
subtitle: "An owner photographs a printed or chalked list. A connected agent reads it, matches it against the site's own items, and proposes the change as a copy of the page for the owner to publish. The photo is disposed of once processed."
brand: plain
standard-margins: true
status: candidate
raised: 2026-11-06
raised-by: "release manager (SM1350 discussion)"
area: content
status-note: "Filed 2026-11-06 under SM1350. Photos are transient (release manager, 2026-11-06)."
---

# Proposed

- **Intake:** the owner takes a photo in the installed app (SM1358) or the manager. It goes into a private per-site queue, not the content tree.
  - Location and device data are stripped on arrival.
  - Only the owner, the service team and connectors granted the queue can read it.
- **Notice:** a new photo notifies the agents' side (email or another notify route), so nothing polls.
- **Connector tools:**
  - `list_photo_updates`;
  - `read_photo_update`, which returns the image;
  - `propose_from_photo`, which takes the photo id plus the proposed changes and returns a copy (SM1354) or availability switches (SM1355), with a preview link;
  - `request_photo`, which asks the owner for one through the client room (SM1360).
- **Matching, not transcribing:** the agent matches what the photo shows against the site's existing rows.
  - Items found switch to available; items missing switch off; changed prices are proposed.
  - Anything new is proposed as a new row through its wizard, so required facts are asked of the owner, never read off the photo.
  - Values the agent is unsure of are flagged on the preview.
- **Disposal:** the photo is deleted as soon as its proposal is published or discarded. A photo nobody processes is deleted after a short limit. Nothing about it stays except the proposal's record of where it came from.
- **No AI in the engine:** the engine makes no AI calls. Reading the photo is the connected agent's work, so the engine holds no API keys, makes no egress and adds no per-site cost.

# Questions for ruling

1. The limit for an unprocessed photo, e.g. 7 days?
