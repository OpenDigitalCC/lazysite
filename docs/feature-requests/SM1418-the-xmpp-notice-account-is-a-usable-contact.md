---
id: SM1418
title: "SM1418: the XMPP notice account is a usable contact"
subtitle: "A person who adds the site's notice account in a chat client got a key dialogue with nothing to trust, because the presence subscription was never mutual. The delivery now answers a subscribe from its recipient and asks for its own."
brand: plain
standard-margins: true
status: shipped
raised: 2026-11-09
raised-by: "release manager, ruling 221"
area: notifications
status-note: "SHIPPED (0.16.9): while connected for a send to a person, Notify approves a subscribe from the configured recipient only, asks for its own once (roster both/to/pending: no repeat); a room gets none; a failed presence step is logged and the send goes on. Plaintext, no OMEMO. t/unit/lib/322; /docs/forms."
---

# What happened

Adding the site's notice account (a bot JID) in Conversations opens "Trust OMEMO
Fingerprints" with no usable keys, and Done stays disabled. The account publishes no
OMEMO keys, and that stays so: notices are plaintext. The subscription between the
person and the account was never mutual, because `notify-xmpp` only connected, sent
and disconnected; it never answered a subscribe.

# What changed

While connected for a send to a person, `Lazysite::Notify` reads the roster once. If
the recipient is not yet subscribed both ways it sends its own `subscribe` (unless one
is already out), and approves a `subscribe` from the configured recipient (bare JID,
case-insensitive). A subscribe from anyone else is ignored. A group chat has no
subscription step. A presence step that fails is logged and never blocks the send.
Every message keeps its plain `<body>`: chat for a person, groupchat for a room.

The docs tell the person to accept the account's request and, on OMEMO-default
clients, to choose Unencrypted in the chat.
