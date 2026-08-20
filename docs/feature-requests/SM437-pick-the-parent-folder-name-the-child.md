---
title: "SM437: pick the parent folder, let the host name the child"
subtitle: "Registering a domain asks the operator to type a content folder freehand. They are typing sites/<hostname> every time, and a typo there is silent - the domain registers, provisions the wrong directory, and serves an empty site."
brand: plain
standard-margins: true
status: candidate
status-note: "REQUESTED 2026-08-20 by the release manager, from doing it repeatedly on the staging instance: 'i have added all under sites/<hostname> but risks typos etc, so selecting parent folder is safer. create if not there.' THE ASK: the Content folder field on the domain form becomes a DROP-DOWN of existing folders - the operator picks the PARENT (sites/) - and the child folder is named from the host and created if absent. So the operator chooses from what exists and types nothing that can be misspelled. WHY IT IS MORE THAN CONVENIENCE, and this is what earns it a filing rather than a nicety: the convention already IS host-derived. Every domain on the staging instance is sites/<hostname>, maintained by hand, by a person, every time. A field whose correct value is DERIVABLE from another field on the same form is a field that should not be typed. SM436 is the same mistake one field to the left - a free-text host that could not be checked against anything - and it cost an operator an afternoon and ended with them blaming DNS. Here the failure is quieter: domain_add ACCEPTS any clean relative path and provisions it (make_path), so a typo produces a registered domain pointing at a new, empty directory. The site serves, with nothing in it, and the original content sits one directory away under the name that was meant. NOT A VALIDATION PROBLEM: the typo'd path is perfectly valid, which is why nothing catches it and why the remedy is to stop asking for it rather than to check it harder. SCOPE, small: the folder list is already available to the manager (the Files surface lists directories), the naming rule is one substitution, and 'create if not there' is what domain_add already does - it calls make_path and ADOPTS an existing directory rather than failing. So this is a form change over machinery that exists. Worth deciding alongside SM436's item 1, since they are the same field pair and a single pass over that form fixes both."
---

# The form today

```datatable
columns: Field | How it is filled | What a mistake does
widths: 5cm | 5cm | X
bold: 1
tone: medium
---
Host | typed freehand | **SM436**: silently serves the default site
Content folder | typed freehand | registers, provisions an empty directory, serves nothing
```

::: widebox
Both values are already determined by the moment the operator reaches the form.
The host is the subdomain they have just created; the folder is `sites/` plus
that host. The form asks them to retype both from memory and then checks
neither against the other.
:::

# What is being asked for

Pick the PARENT from a list of folders that exist. Name the CHILD from the
host. Create it if it is not there.

The operator's own words for why: *selecting parent folder is safer*. The list
cannot be misspelled, and the part that varies per site is derived rather than
retyped.

# Why it is cheap

- The manager already lists directories - the Files surface does it, and the
  domain form is in the same manager.
- The naming rule is `<parent>/<host>`, the convention every existing domain on
  the instance already follows by hand.
- `domain_add` already does the create-or-adopt half: it calls `make_path` when
  the directory is absent and adopts an existing tree when it is present, so
  "create if not there" needs no new behaviour underneath the form.

# Worth deciding with SM436

SM436 asks for the host field to be validated because a bad value there cannot
be corrected afterwards. This asks for the folder field to be derived because a
bad value there is undetectable. They are adjacent fields on one form, both
free text, both with a value the system already knows - and one pass over that
form addresses both.
