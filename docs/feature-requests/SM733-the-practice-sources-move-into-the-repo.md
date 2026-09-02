---
id: SM733
title: "SM733: the practice sources move into the repo that ships them"
subtitle: "The briefing installed on every site was built from two files in another agent's trees. The site agent still maintains them; the release side is now custodian of what ships - and the three client names that blocked the gate are redacted."
brand: plain
standard-margins: true
status: shipped
---

# What moved

`docs/practice/authoring-practice.md` and `docs/practice/app-practice.md`, from
`/srv/projects/lazysite-sites/AUTHORING-PRACTICE.md` and
`/srv/projects/lazysite-apps/APP-PRACTICE.md`.

`tools/import-field-practice.pl` reads them there now. `docs/practice/README.md`
records who maintains what.

# Why

**SM597 had already filed the structural half**: reading them from outside
coupled every gate to files the repository does not own.

**SM731 showed the cost.** The 2026-09-02 update named three clients - two site
names with a comparative judgement about which was badly built, and a client
project - in a document that installs on every site. Nothing between the notes
and the shipped artefact could see it until the import refused, and the people
who could act on it did not hold the files.

The split now matches responsibility: **the site agent maintains the content,
because it is theirs and their judgement about it is better than anyone's; the
release side holds the copy that ships, because it answers for what ships.**

# The redaction

Done here, as custodian, rather than asked for and waited on:

- Two named client sites and the judgement about one of them became "One site
  writes... Another renders..." - identical force, no client in it.
- A client project named as the origin of a ruling became "a custom
  stock-corrections build" - same provenance.
- The anonymous statistics beside them were left alone. They name nobody and are
  exactly the right shape.

**`t/lint/89` is green again** and the release gate is unblocked. It had been red
since 2026-09-02, correctly, and I would rather record that a gate blocked a
release for two days than that it was worked around.

# What did not change

The guard SM731 added stays and is now beside the files it protects. The site
agent's authority over the content is unchanged - this is a change of address
and custody, not of editorial control, and the README says so in as many words
so a future reader does not infer a demotion from a file move.

**The originals are left in place**, not deleted. Two copies can drift, and the
importer reads this one, so this one is canonical - but removing files from
another agent's tree is that agent's act, not mine. Filed to its inbox.
