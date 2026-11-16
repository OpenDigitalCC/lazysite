---
id: SM1458
title: "SM1458: the check's advice names the user who owns what it could not read, and the full command"
subtitle: "Three wording faults in the advice a check walk gives for something it could not read: it can send the running user to run the check as themselves, it spells the command bare in one place, and it names root twice."
brand: plain
standard-margins: true
status: candidate
raised: 2026-11-16
raised-by: "the 0.17.0 field walk (T2.3, T2.4)"
area: check
status-note: "OPEN. Target 0.17.x edge. The advice text only; what the check reads and reports is unchanged. Follows SM1447."
---

# What the walk found

Run as the user who owns the store files, with a directory the check could not read, the
address-rule walk and the address-profile slot walk advised "run the check as X, who owns the
store files" with X the user already running it. What they could not read belonged to
someone else. Separately, the advice under the db: template, form-pattern and old address
test walks spelled the command as a bare `lazysite`, where every other advice line spells it
as this host runs it, and one line named root twice: "run the check as root, who owns what it
could not read (...), or as root".

# Why

SM1447 made the advice name the owner of the store files. For a walk that could not read
something, the owner that matters is the owner of that thing, and when that is the user
running the check, the advice is no help at all. The advice is the one thing the operator
reads next, so it has to be right.

# The request

R1
: When the user the advice would name is the one running the check, it names the real owner
  of what could not be read (as the other walks do), never the running user. The address-rule
  walk and the address-profile slot walk say what they could not read, so the advice can name
  its owner. Where all of it belongs to the running user, its permissions are the fault, and the
  advice says so rather than naming anyone to run the check as.

R2
: The advice under the db: template, form-pattern and old address test walks spells the
  command as every other advice line does (the host's own spelling, with its full path where
  there is no `lazysite` on the path), not a bare `lazysite`.

R3
: Where the owner of what could not be read is root, the advice says root once: "run the check
  as root, who owns what it could not read (...)", with no ", or as root" after it.
