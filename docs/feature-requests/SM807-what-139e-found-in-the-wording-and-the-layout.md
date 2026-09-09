---
id: SM807
title: "SM807: what 139E found in the wording, the layout and the save"
subtitle: "Eight refs passed, one failed (SM804), one was mixed. This is the residue: a remedy that sent the only account able to fix something to look for somebody who could fix it, a landing page headed for the wrong thing, a row action group with no anchoring, a refusal that named what failed but not what would work, and a mapping validated at call time that should be validated at save."
brand: plain
standard-margins: true
status: shipped
status-note: "FIXED 2026-09-09 on claude/sm807-139e-findings. Each verified against the source before it was accepted. The one NOT fixed is 139E-06's nav marking - the engine renders 16 items with 5 locked for the capability set the field tested, so what the field saw is the PRE-SM775 template and the question is why the deployed copy is old. That is a deployment question, filed as SM808."
---

# The remedy that sent a user manager to find a user manager

`/manager/config`, to an account without `manage_config`, said:

> ... A user manager can grant it on the Groups page.

Correct for an account holding no `manage_users`: it means *find somebody
else*. Said to an account that **is** a user manager it means *find yourself*.
The field put it exactly right: the sentence sends the one account that can fix
it to look for the person who can fix it.

It now depends on who is reading it - "You can grant it on the Groups page",
with a link - and the difference is what the ref asked to see.

# A landing page headed for the wrong thing

SM775 stopped forwarding an account without `manage_config` to a settings page
it cannot read, and landed it on its own account sheet instead. The body was
right; the **heading** still said `SITE SETTINGS`, because the layout renders
the front-matter title as the h1 before the body. So the field read it as still
landing on the settings page, and the half of the complaint that was fixed
looked unfixed.

Titled `Your account`, which is the only case that reads it - a holder of
`manage_config` is redirected before paint.

**The first attempt invented a `page_title_when_no_config` front-matter key.**
Nothing reads it. That is a declaration the code ignores, which is the thing
this project keeps filing against, and it lasted about four minutes.

# A row action group with no anchoring

`.mg-row-actions` had no `margin-left: auto`, so it sat wherever the inline
content before it happened to finish. On the connectors list the credential
state moved 130px between rows, tracking the length of the URL above it - and
which connectors have a credential is the one thing a reader most wants from
that list, so it could not be scanned down a column.

The field located it precisely, including that the class is shared and that
Backups has a single row so the jitter cannot show there. Fixed in the shared
class, in all three sheets.

# A refusal that named what failed but not what would work

    this connector does not permit authenticated invocation

For a connector whose whole point is that it runs on a timer, `scheduled` is
the word that closes the question. It now says which modes it does permit.

The field measured this against the redirect refusal from SM790 - *"the best
worded refusal in the release"* - which gives status, rule, reason and the
address to reconfigure with, all in one sentence. That is the standard to hold
the others to.

# A mapping validated too late

A `row_map` naming a column the table does not have was **accepted at save** and
could only fail at the call. `_normalise` checks the shape of a name; only the
table knows whether it exists.

Refused at save now, naming the unknown column and listing the ones the table
has. **A table that cannot be read is not a refusal**: the descriptor may be
unreadable for reasons that have nothing to do with this connector, and
blocking the save on it would make an unrelated fault look like a bad mapping.
Unvalidated is not invalid.

# Two notes from the field worth keeping

**The plan said `failed`, the engine says `refused`.** The engine's word is
better - the endpoint did not fail, the connector declined - and the plan is
what should change. Recorded so the next plan uses the engine's vocabulary.

**Two accounts differ only in case** (`Claude.ai` and `claude.ai`) on the edge
roster. Noticed in passing during 139E-07, not a finding for that ref, and
worth someone confirming it is deliberate. Not an engine question unless the
answer is no.

# Provenance

`inbox/2026-09-09-139E-results-0.13.9.md`.
