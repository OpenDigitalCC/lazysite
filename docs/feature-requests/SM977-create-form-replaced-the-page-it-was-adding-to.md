---
id: SM977
title: "SM977: create_form replaced the page it was adding a form to"
subtitle: "MCP create_form, called with an extensionless path as its schema describes, read a file that does not exist and wrote a fresh scaffold over the page."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-09
raised-by: the developer agent, found during SM976 Q15f (n317)
area: data-loss
status-note: "SHIPPED (PENDING): create_form reads the file it writes (/about and /about.md are both /about.md), appends to it, adds front matter to a page that has none, refuses a page it cannot read, and saves with the read's mtime. t/integration/119."
---

# What was wrong

`create_form` is documented to add a form to a page: "Inserts a native
:::form block into the page and sets its form: NAME front matter", with the
path "created if absent". It read the page by the caller's spelling of the
path and wrote it by the resolved one (SM655 resolves the path to `/$slug.md`
for the save). So the idiomatic call, `create_form {path: "/about"}`, read
`/about`, found nothing, and saved a fresh scaffold (`title: Contact`, the
form, nothing else) as `/about.md`. The page's own text was lost. The answer
was `ok: true`.

Two more cases lost a page with any spelling:

- A page with text and no front matter, which is optional in lazysite. The
  scaffold replaced it.
- A page that exists and could not be read (an ACL denial, an unreadable
  file). The read's failure was taken as "no page", and the scaffold replaced
  it.

The n317 agent's probe (tmp/q15f-create-form-probe.out, on main's script)
shows the first case.

# The fix

The contract is unambiguous: the tool adds to the page and creates it only
when it is absent. So `_create_form` reads `/$slug.md`, the file the save
writes, and decides from that read:

- If the page reads, the block is appended. With front matter, `form: NAME` is
  added as before. Without front matter, a front matter block naming the form
  goes before the text. A page bound to a different form is still refused, and
  so is one whose result the processor would not read as binding the form.
- If the read answers "not found", the page is created, as before.
- Any other refusal (unreadable, ACL, binary) is returned and nothing is
  written.

The save carries the read's mtime, so an edit made between the read and the
save is refused as a conflict rather than overwritten.

# Evidence

t/integration/119 turns the probe into assertions:

- `/about` on an existing page keeps its title and text and binds the form.
  The served page carries both.
- `/team.md` behaves the same way.
- A page with no front matter keeps its text and gains the front matter.
- A page bound to another form is refused and left unchanged.
- A page the tool cannot read is refused and left unchanged.
- A new path is scaffolded.

With main's `lazysite-mcp.pl` in place (tmp/q15g-sabotage-a.sh), 12 of its 23
assertions fail. Restored by cp and checked with cmp, it passes.

# The other page-writing tools

tmp/q15g-other-tools-probe.out runs each tool against an existing `/about.md`
with the extensionless path and the `.md` path:

- `create_page` refuses an existing page under both spellings (SM852).
- `move_file` and `rename_page` refuse an existing target.
- `replace_text` reads and writes the same path, so `/about` is "not found".
- `write_file` and `upload_file` overwrite `/about.md`, which is their
  contract ("Create or overwrite"). With `/about` they write a separate file
  named `about`. That is SM655's dead-page class, and no page is replaced.
- `copy_file` to `/about.md` **overwrites the existing page**. Its description
  says "to a new path", and the manager's `action_copy` refuses an existing
  target with `exists`. MCP's `copy_file` reads the source and calls
  `action_save`, so it skips that check. Not changed: this changes what the
  tool does on an existing target. Recommended: route `copy_file` through
  `action_copy`, which refuses an existing target and already applies the
  form-binding rule to a copy.
- `copy_file`, `move_file` and `upload_file` to `/about` write a file named
  `about`, as `write_file` does.

The control API and WebDAV take paths literally and do not add `.md`, so this
class cannot occur there.

# Related

[[SM655]], [[SM852]], [[SM976]].
