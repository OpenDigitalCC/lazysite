---
id: SM739
title: "SM739: an error string says nothing about the host, and the two-reader fixture that proves a refusal fires"
subtitle: "Three leaks in three passes taught the same lesson: sanitising somebody else's output is a losing position. The converter failure is fixed text now, a lint catches the class at the source, and the refusal that had never executed has a fixture that would notice if it stopped."
brand: plain
standard-margins: true
status: shipped
---

# Why a denylist was the wrong shape

Three separate incidents, each found from outside:

1. **SM713** - a data error carried an absolute path, a source file and line,
   and the driver's own vocabulary.
2. **SM738** - the composed-PDF failure carried `/home/<account>/web/<site>/...`
   and a date stamp.
3. **And then SM738's own fix**, on the very next pass: the date came back
   **inside an echoed command line** (`--metadata=date:"Wednesday 02 September
   2026"`), along with the pandoc invocation and a mojibake byte of stderr.

The third is the argument. SM738 filtered path-shaped tokens and one date
phrasing; the converter simply said it differently. **A filter over another
program's output is only ever as good as the last thing that got past it**, and
every release of that program may phrase something new.

So the converter failure is now **fixed text** - "the document could not be
produced. The converter refused it; the reason is in the site log." The output
goes to the log, where an operator debugging the engine looks for it and where
no HTTP client can read it. The caller loses nothing they could act on: none of
pandoc's chatter told them how to fix their document.

# The lint, proposed by the field agent and earned three times

`t/lint/112` checks the **source**, not the output: a caller-facing error string
that interpolates an absolute path, a `DBD::`/`DBI` prefix, or an echoed command.
That is where the decision is actually made, and it would have caught all three
incidents without a running instance.

**Scoped deliberately.** It reads the eleven caller-facing surfaces and only
lines building an `error =>`, because a comment, a log line or a test fixture may
legitimately name a path - and a lint noisy enough to be switched off catches
nothing at all.

It also guards SM713's cleaner specifically: a raw `$@` reaching a caller again
from `Data::Tables` fails, since that fix was one cleaner standing in front of
eight call sites and any new site could bypass it.

# The two-reader fixture

`t/unit/plugins/44`. The refusal it covers - SM706's "refused rather than built
without that part" - **had never executed once in its life** before 0.11.12,
because the existence check looked only where a public file lives and ran before
`may_read` was consulted.

**One reader is not enough, and that is the whole point of the file.** Testing
only the denied reader passes just as well when the part is invisible to
everybody - which is precisely the state that hid this for a release. The
authorised reader is what distinguishes *refused because you may not* from
*missing*.

Three cases: a part in the private store is found for an authorised reader; a
denied reader gets the refusal naming the part, in the SM706 wording; and a part
that genuinely does not exist is still reported missing - because "you may not
read it" and "it is not there" are different answers and must stay different.

Sabotage-verified: restoring the docroot-only check fails five assertions.

# What the field agent got right that we had not

Their filing proposed this lint after the first leak and repeated it after the
second and third. It was the right call each time, and it took three incidents
before it was built. Recorded because the lesson is about the queue, not the
code: **a cheap check proposed by whoever keeps finding the same class of defect
is worth building the first time it is suggested.**
