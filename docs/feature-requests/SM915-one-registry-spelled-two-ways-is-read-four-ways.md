---
id: SM915
title: "SM915: one registry spelled two ways is read four ways, and one of them writes a second list"
subtitle: "SM817 renamed the extension list from `plugins:` to `extensions:` and said both spellings open the same list, so a site cannot end up with two lists that disagree about what is enabled. Measured 2026-09-29: of the four places that read that list, one accepts both spellings and three do not - and the one that WRITES it appends a second `plugins:` block to a site that uses `extensions:`, which is the outcome the rename's own comment rules out."
brand: plain
standard-margins: true
status: candidate
raised: 2026-09-29
raised-by: engine agent, while building SM485's email transport
area: extensions
---

# How this was found

Not by review. SM485's ruling makes the Form SMTP extension the transport for
notice email, so the build needed a predicate for "is that extension enabled".
`Lazysite::Notify` already had a private one, and a probe comparing it against
`Lazysite::Manager::Plugins` disagreed on a site using the newer spelling.

The first version of that probe wrote the list to a `plugins.conf` that does not
exist, got `0` from both readers in both spellings, and would have been read as
agreement. It proves nothing when every answer is the same: the measurement below
returns a `1` for at least one reader, so it can tell agreement from a broken
fixture.

# What was measured

`tmp/sm485-repro.pl`, against a real site tree:

| `lazysite.conf` header | `Notify::_plugin_enabled` | `Plugins::plugin_enabled` |
| --- | --- | --- |
| `plugins:` | 1 | 1 |
| `extensions:` | **0** | 1 |

Then every reader of that list in the tree, found by pattern rather than by
memory:

| Site | Accepts `extensions:` | What it decides |
| --- | --- | --- |
| `lib/Lazysite/Manager/Plugins.pm:109` | **yes** | `plugin_enabled` - the gate on a contract plugin |
| `lib/Lazysite/Notify.pm:302` | no | whether a notice reaches a non-bell endpoint |
| `lazysite-processor.pl:8461` | no | `enabled_plugins` for the layout, which hides nav entries |
| `lib/Lazysite/Manager/Plugins.pm:567` | no | **the WRITER** - enable and disable |

SM817's comment sits at the one site that is right:

> `extensions:` is the name, `plugins:` is the old one, and a site keeps
> whichever it has. Both open the SAME list - there is one registry, spelled two
> ways, so a site cannot end up with two lists that disagree about what is
> enabled.

# The writer is the serious one

Read at `lib/Lazysite/Manager/Plugins.pm:567-607`. On a site whose header is
`extensions:`, `$found_block` never becomes true and `$in_plugins` is never set,
so the header **and every one of its entries** fall through to `@before` and are
preserved. `@plugins` is therefore empty, and the rebuild at `:601-603` emits
`plugins:` with only the script just added.

So **enabling one extension on an `extensions:` site writes a second list.** The
conf then carries both headers, and the four readers split: the one at `:109`
merges both and sees everything; the other three see only the `plugins:` block
and read every previously-enabled extension as disabled.

`disable` is worse in a quieter way: the entry is not in `@plugins`, so
`grep { $_ ne $script }` removes nothing, the conf is rewritten without the
extension being disabled, and the result is reported `ok`.

# Why it has not been noticed

Every shipped starter conf uses `plugins:`, and so does every fixture in `t/`.
The divergence only appears on a site that adopted the newer spelling, which is
the spelling SM817 introduced as the name. Nothing fails loudly: a notice is
still written to the bell, the nav simply hides an entry, and the writer reports
success.

# What to build, and the one question it needs answered

Mechanically the three readers are one regex each - the shape at `:109` is the
one to copy, and a lint that every reader of the list accepts both spellings is
the gate that stops a fifth copy drifting. That much is not a decision.

**The writer needs a ruling, because a site may already have two lists.** A
site that enabled an extension through the manager since SM817 landed has both
headers now, and the fix has to decide what to do with what it finds:

- **Write back under the header the site already uses** - the conservative
  reading of "a site keeps whichever it has", and it leaves an existing two-list
  site with two lists.
- **Merge on write** - collapse both headers into the one the site started with,
  which repairs a damaged conf but edits a list the operator did not ask to be
  edited in that call.
- **Refuse and report** when both headers are present, naming the file, so an
  operator fixes it deliberately.

That is a ruling rather than a size, and it is the reason this is filed rather
than fixed in passing.

# What SM485 did with it

Fixed **only** `lib/Lazysite/Notify.pm:302`, because the email endpoint cannot
be reached at all on an `extensions:` site without it, and left the other three
here. That fix is named in SM485's commit rather than hidden in it. Its own
consequence is worth stating plainly: **XMPP notice delivery has been silently
off on every site using the newer spelling** since SM817, which is a shipped
defect this build happened to walk into, not one it introduced.

# Not measured, and an operator question rather than a dev one

Whether any live site currently uses `extensions:`, and whether any has both
headers. That is a fleet question, answerable with `lazysite-check` rather than
from this tree, and it decides how urgent the writer half is.
