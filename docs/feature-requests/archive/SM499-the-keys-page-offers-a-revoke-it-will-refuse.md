---
title: "SM499: the Keys page offers a revoke it will always refuse"
subtitle: "SM439 deliberately lists interactive accounts holding machine channels - 'listing is not offering' - but the page renders the Revoke key button on those rows anyway, so the operator meets the refusal instead of the design."
brand: plain
standard-margins: true
status: shipped
status-note: "OBSERVED BY THE OPERATOR 2026-08-24 on the Sessions and keys page: a row 'manager / webdav / unknown / not used yet', and clicking Revoke key answered fail - 'manager is an interactive account - its credential is a login password, not an access key. Manage it on the Users page.' EVERY PIECE OF THAT IS DESIGNED except the click being possible: SM439 lists interactive accounts that hold a machine channel precisely so no access is hidden (webdav is HTTP Basic - live whenever used, no session, previously listed NOWHERE), its comment says plainly 'listing is not offering' and 'revocation still refuses: cmd_key_revoke has its own guard on ui, which is where that decision belongs' - and keys-list already emits interactive on the row for exactly this moment. The page never consumed the flag: sessions.md rendered the Revoke key button unconditionally, so the designed refusal became the operator's first contact with the design. The codebase's own words for this shape, from the data-tables nav test: a link that refuses when followed teaches an operator to distrust the menu. FIX, one gate: an interactive row shows 'interactive - manage on the Users page' (linked) where the button would be; machine rows keep the button unchanged. The refusal guard stays exactly where SM439 put it - the UI change is presentation of a decision, never the decision. SHIPPED 0.10.29."
---

# What the operator saw

A keys row for `manager` (channels: webdav, never used), a Revoke key
button, and on clicking it:

    'manager' is an interactive account - its credential is a login
    password, not an access key. Manage it on the Users page.

# Why the row is right and the button is wrong

SM439's decision, quoted from its own comment: an interactive account
holding a machine channel is LISTED - hiding it left WebDAV access
recorded nowhere - and "listing is not offering"; revocation refuses in
`cmd_key_revoke`, "which is where that decision belongs". The row even
carries `interactive: true` for the page to consume. The page did not
consume it: the button rendered unconditionally, so the operator's first
contact with the design was its refusal.

# The fix

`sessions.md` gates the control on the flag the row already carries: an
interactive row shows "interactive - manage on the [Users page](/manager/users)"
where the button would be. The guard in `cmd_key_revoke` is untouched -
the UI presents the decision, it never makes one (SM286).
