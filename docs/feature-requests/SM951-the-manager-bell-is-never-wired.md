---
id: SM951
title: "SM951: The manager bell is never wired: its script runs before the bell exists"
subtitle: "No badge, and a click throws \"mgToggleNotif is not defined\", on every manager page since at least 0.10.0."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-07
raised-by: the sites agent, 0.15.2 edge walk R1 (owner's Firefox), 2026-10-07
area: manager
status-note: "SHIPPED (PENDING): the block runs when the document is ready. t/unit/lib/198 loads the layout head script and bell in headless Chromium; on the 0.15.2 layout it reported handler=undefined, as the owner saw; after the fix the handler exists and a click opens the panel. R1 of the 0.15.2 plan can be walked again."
---

# Measured

`starter/lazysite/manager/layout.tt`: the notifications block is an immediately
invoked function inside the one inline `<head>` script. It opens with
`if (!document.getElementById('mg-notif')) return;` (line 406). `</head>` is line
635 and the bell button is line 654, so when the function runs the bell does not
exist, it returns, and `window.mgToggleNotif`, the badge fetch and the panel's
click delegation are never set up. No `DOMContentLoaded` or `readyState` check
exists in the file. The guard sat in `<head>` in v0.10.0, v0.13.0, v0.14.4,
v0.15.0 and v0.15.1.

The owner's browser (Firefox, edge, 0.15.2): no badge on any manager page;
a click logs `Uncaught ReferenceError: mgToggleNotif is not defined`. The
`notices` action answers correctly over the token channel (29 unread).

`t/unit/lib/196-a-notice-is-read-on-its-own.t` extracts the function from the
template by regex, so it passes whether or not a browser can reach it.

# Proposal

Run the block when the document is ready (or move it after the bell), and add a
test that loads the rendered manager page and proves the handler is defined once
the page has loaded - a test that fails on today's template.

# Done when

On a rendered manager page the bell shows the unread count and the panel opens;
the new test fails with the guard back in `<head>`.
