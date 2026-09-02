---
id: SM738
title: "SM738: a composed document is made of real pages"
subtitle: "The composed PDF worked only when its parts had no front matter, which is not what the feature is for; a part behind a read ACL was 'no such part' even to a reader authorised to read it; and the failure named the host. Three faults, all found from outside on 0.11.11, all invisible to the gate for the same reason - the fixtures described a shape the feature is not for."
brand: plain
standard-margins: true
status: shipped
---

# The three

Found by the edge testing agent against 0.11.11, hours after SM732 made the
render reachable at all.

## 1. Parts arrived as whole documents

Every source was handed to the converter, which concatenates them. A part that
is a **real page** carries its own `---` front matter, so a composed document
arrived with several YAML blocks and the typesetter died.

It worked only when the parts had no front matter. **That is not what the
feature is for**: "compose a document out of pages that already exist" means the
parts ARE pages, and a page has front matter.

The primary keeps its own - that is where `title`, `brand` and the `parts` list
live. Each part is now copied into the scratch directory with its head block
removed, and those copies are what the converter reads. A `---` further down is
a horizontal rule and survives.

## 2. A gated part was missing rather than refused

The existence check was `-f "$docroot/$prel"`, which is only where a **public**
file lives. A read ACL MOVES content into the private store, so:

- an authorised reader could not compose a gated part - "no such part" for a
  file they could read over WebDAV; and
- the check ran **before** the `may_read` branch, so SM706's "refused rather
  than built without it" message **never fired at all**.

Two faults from one line. The protective outcome for a denied reader held, but
by accident and with a misleading reason.

**The resolver is passed in**, like `may_read` and for the same reason: where a
file lives is the engine's business, and a plugin that learned the private
store's layout would be a second copy of that knowledge. Without one, the public
path is the answer - which is what a standalone run wants.

## 3. The failure named the host

`...did not produce a document: .../home/ispadmin/web/<site>/public_html/...
on Wednesday 02 September 2026`. Same rule as SM713 one surface over: what
crosses the wire is what the reader can act on; the full text goes to the log.

# Why the gate missed all three

`t/unit/plugins/41` composes from parts that carry **no front matter**, and
passes no `resolve`. So neither fault could appear in it. Eleven sabotages,
every one of them against a shape the feature is not for.

**That is the more useful finding than any of the three bugs.** A fixture that
describes an easier case than the real one does not fail - it passes, and it
keeps passing, and it makes the suite look like coverage.

`t/unit/plugins/43` uses parts that are real pages, and asserts the resolve
happens before the may_read branch rather than merely that both exist.

# Still not proved

**The `may_read` branch itself.** The agent could not reach it: the existence
check preempted it, so it has never fired. With this fix it should, but proving
that needs a composed render run twice - once as a reader authorised for the
gated part, once as one who is not. That is a two-reader integration fixture and
it is the thing to build next, because a refusal nobody has seen fire is a
refusal on trust.
