---
id: SM809
title: "SM809: the daemon is findable, and a missing plugin parameter is named as missing"
subtitle: "Nine steps to answer 'is the daemon running', one of them reading the manager UI's own JavaScript. The daemon was running the whole time. Nothing about the information was missing - only the path to it, which is the kind of defect no test of behaviour catches."
brand: plain
standard-margins: true
status: shipped
status-note: "FIXED 2026-09-09 on claude/sm809-the-daemon-is-findable. The plugin is named 'Persistent runtime (daemon)', so searching for the word everyone uses finds it. All three plugin actions resolve on EITHER `plugin` or `script` - `plugin` was declared and then ignored, which is why sending it produced 'Plugin not found' - and a missing one is named as missing with both spellings and where the ids come from. The practice document now says that a plugin's actions come from plugin-list and nowhere else, with the daemon status call written out. The unrecognised-action message is NOT changed; see below."
---

# What happened

The field was asked whether the daemon was running on edge. It was. Answering
took nine steps, ending in reading the manager page's JavaScript to discover
the real contract - and the ref was recorded as blocked on the release manager,
which was wrong. The filing is the field's own account of why it was wrong for
reasons in the product rather than in their method, which is the useful way to
report it.

# Four findings, three fixed

**The name shared no token with anything else it is called.** The plugin was
`Persistent runtime`. Its id is `daemon`, its script `daemon.pl`, its config
`daemon.conf`, its jobs `daemon-heartbeat` and `connectors-sweep`, and every
plan and filing in this campaign calls it the daemon - so searching the manager
for the word everyone uses returned nothing, and the field read all ten plugin
names and guessed. It is now `Persistent runtime (daemon)`: one word, and it
still says what it is for somebody who does not know the word.

**`plugin` was declared and ignored.** All three of `plugin-read`,
`plugin-save` and `plugin-action` declare a `plugin` query parameter, receive
it as `$plugin_id`, and resolved on `$script` alone. So a caller sending the
parameter the declaration names got **"Plugin not found"** - a sentence about
the plugin when the fault was the parameter, which is exactly where it sent the
reader. This is the same family as the three refusals fixed in 0.13.8 and
0.13.9, and the field said so.

Both spellings resolve now, and the two refusals are told apart: a missing
parameter names itself, both channels and `plugin-list`; a plugin that really
is not installed says *that*, because that is what is wrong.

**A plugin's actions were invisible to both API documents.** They cannot be in
`describe-capabilities` - they are the plugin's own declaration, not the
engine's - but nothing said where they *are*. `plugin-list` returns them, and
the field found that array exactly as useful as it should be. The practice
document now says so, with the daemon status call written out, and notes that
plugin actions are cookie-only so no amount of reading `actions-list` will find
them.

# What was NOT changed, and why

**The unrecognised-action message.** The field proposes that `daemon-status`
could say *"no such action - the daemon is the Persistent runtime plugin"*, on
the model of the excellent cookie-only refusal for `users`. That refusal works
because `users` **is** an action and the engine knows exactly where it lives.
`daemon-status` is not an action and never was; matching it would mean carrying
a table of plausible-but-wrong names and what they were probably reaching for,
and the first wrong guess in that table would be worse than the honest
"unrecognised".

The two smaller fixes remove the need: with the word `daemon` in the plugin
name and `plugin-list` documented as the source of a plugin's actions, the path
from "I want the daemon's status" to the call is two steps and needs no
guessing at action names.

If the release manager wants the suggestion anyway, the shape that would work
is narrower: an unrecognised action whose *prefix* matches an installed plugin
id could name that plugin. That is checkable without a guess table, and it is
recorded here rather than built.

# The counter-example, which the field was right to include

Once found, the status output needed no interpretation: every job, its actor,
its outcome and a meaningful detail. The information was never the problem.

# Provenance

`inbox/2026-09-09-the-daemon-is-not-discoverable.md`, filed at the operator's
request after 139E-04.
