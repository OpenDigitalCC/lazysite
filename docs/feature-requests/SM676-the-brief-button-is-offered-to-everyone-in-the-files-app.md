---
title: "SM676: the Brief button is offered to everyone who can open a file's expander, and the write behind it is not"
subtitle: "Release manager, 2026-08-28: 'i had brief option even though i didnt have briefs permission' - and the read genuinely does not need it, while the write does"
brand: plain
standard-margins: true
status: shipped
status-note: "SHIPPED (PENDING). The Brief button no longer renders unconditionally: it appears only for a caller who may READ a brief (manage_content OR manage_briefs, unchanged and deliberate) and only while the briefs plugin is on. A caller who may read but not append gets a button labelled read-only and a panel that SHOWS the brief and says which capability an entry would need - rather than prompting for text and refusing the save, which put the refusal after the typing. The asymmetry itself is unchanged and is asserted by the test, so that if brief-append is ever widened to manage_content this file is revisited rather than left asserting a distinction that has gone. The capabilities are fetched ONCE at page init, not per directory - a property of the session. Sabotage-verified three ways, including that the guard must come BEFORE the prompt, since checking after it is precisely the defect."
---

# Three facts, and only one of them is a defect

**The button is ungated.** `files.md` renders `briefButton(f)` unconditionally
in the expander's action row. Every other conditional control there is gated -
`migrateToLocal` on the filename, `toggleHistory` on `GIT.enabled &&
isEditable(...)` - and this one is not gated on anything at all.

**Reading a brief does not need `manage_briefs`, by design.** The gate is
`brief-read => manage_content|manage_briefs`, on both the token and cookie
paths. Anyone in the Files app holds `manage_content` by definition, so
everyone there can read briefs. That is defensible: a brief is about a content
object, and its reader is usually the person editing that object.

**Appending DOES need `manage_briefs`, and only that.** `brief-append =>
manage_briefs`. Not `manage_content`, not either-or.

So the button is offered to everyone, the read succeeds for everyone, and the
write is refused for anyone without the narrower grant.

# What the operator actually experiences

1. Open a file's expander. The Brief button is there.
2. Press it. The brief is read and shown - this works.
3. `window.prompt` asks for an entry. Type one.
4. The append is refused.

The refusal arrives after the typing, which is the worst moment for it, and the
operator has no way to know in advance that the control was not theirs to use.
It is the same shape as SM501's expired form submission and SM655's create_form
that reported success: the surface let somebody complete work it was never going
to accept.

With the briefs PLUGIN disabled it is worse still: step 2 fails too, with "The
briefs plugin is disabled", from a button nothing suggested would not work.

# The fix, and why it is not just "hide the button"

Hiding it from a caller without `manage_briefs` would remove the READ, which
that caller is entitled to and which is the more common use. The control has two
capabilities behind it and needs to reflect both:

- No `manage_content` and no `manage_briefs`: no button.
- `manage_content` only: the button reads, and offers no append - the prompt
  never opens, and the panel says the entry needs `manage_briefs`.
- `manage_briefs`: read and append, as now.
- Briefs plugin disabled: no button at all, or one that says so before it is
  pressed. This is [[SM675]]'s question and should be answered the same way in
  both places.

The Files page does not currently know the caller's capabilities - it fetches no
`whoami` - so this needs the same capability context SM675 needs for the Groups
grid. That is the argument for doing them together.

# Worth deciding at the same time

Should `brief-append` accept `manage_content` as `brief-read` does? The
asymmetry is what produces the trap: read admits either, write admits one. If
the intent is that a content editor may annotate what they edit, the write
should match the read and `manage_briefs` becomes the grant for an agent that
ONLY writes briefs. If the intent is that briefs are a separate editorial
record, the asymmetry is right and the UI simply has to show it.

Recorded rather than assumed: it is a capability decision, and this filing is
about the surface offering what it cannot deliver either way.

# Related

[[SM675]] (a capability backed by a plugin says so - same missing capability
context, same page family), [[SM655]] (a tool that reported success while
writing something the site would not serve), SM245 (briefs moved to the plugin
store, which is when this button lost its `is_brief` hint and became
unconditional), SM502 (the modal rework this button is waiting for).

# Not started
