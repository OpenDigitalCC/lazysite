---
id: SM864
title: "SM864: the Hestia installer's first-run bootstrap calls `setup-manager`, which SM659 removed - so a fresh install creates no account, announces that it did, and retries for ever"
subtitle: "SM659 renamed the verb to `setup-sysop` and deliberately kept no alias. The runbook was updated; the shipped deploy script and the Debian README were not. The users tool answers an unknown command with a usage message and EXIT 0, so the installer cannot see the failure - and the first-run sentinel is never written, so every later deploy repeats it. The `manager` accounts on existing installs are the other half: the old verb took no `--user` and defaulted to an account literally called `manager`, the shared role account SM659 exists to prevent."
brand: plain
standard-margins: true
status: partial
status-note: "SHIPPED 2026-09-12 for 0.13.15, in part. DONE: the deploy script no longer calls the dead verb and no longer runs a bootstrap at all - it says there are no accounts, which is a coherent state, and prints the setup-sysop command, because that verb requires a name and a deploy cannot know who the first person is. debian/lazysite-hestia.README.Debian is corrected. t/lint/138 checks every shipped installer, README and runbook against the dispatcher, so the next rename cannot land in one reader and survive in another - verified by putting the dead call back. NOT DONE: lazysite-check naming a shared-looking role account, which is how an operator would learn their existing `manager` account is there. Nothing renames or deletes it - an operator may be signing in with it - so surfacing it is the whole remaining job, and it belongs with lazysite-check's other site-state reports rather than here."
raised: 2026-09-12
raised-by: release manager (two fresh installs each carrying a `manager` account)
area: packaging
---

# How this was found, including my own error

The release manager asked why `setup-sysop --user sjm` had also produced a
`manager` account. I probed `setup-sysop` in a hand-made docroot, found it
creates exactly one account, and answered that nothing else had been created.

**That was the wrong measurement.** The claim was about a *fresh install*, and my
probe never ran the install path. The release manager pushed back with the actual
evidence - two fresh installs, two accounts each - and the install path is where
the answer is. Recorded because the lesson is general: when the report names an
environment, reproduce in that environment, not in the nearest convenient one.

# What is broken now

`installers/hestia/lazysite-hestia-deploy.sh:184`, inside the first-run block:

```bash
if [ ! -f "$LZ/auth/groups-settings.json" ]; then
  echo "==> first-run manager setup"
  sudo -u "$U" perl "$DOM/tools/lazysite-users.pl" --docroot "$DOC" setup-manager
fi
```

`setup-manager` is not a command. SM659 renamed it to `setup-sysop` **and
deliberately kept no alias** (tools/lazysite-users.pl:758 says so). Run against
the current tool:

```
$ perl tools/lazysite-users.pl --docroot <fresh> setup-manager
lazysite-users.pl: unknown command 'setup-manager'
... usage ...
$ echo $?          # measured WITHOUT a pipeline - see the correction below
2
```

**CORRECTION, 2026-09-12.** The first version of this filing said the tool exits
**0**, and built an argument on it: that the installer could not detect the
failure even if it checked. That was wrong. I measured it as
`... setup-manager 2>&1 | head -5; echo "exit=$?"`, which reports **head's**
status, not perl's. The dispatcher's `else` branch does `usage(); exit 2;` and
does so correctly.

The defect is real and simpler than I filed it. On a current build, a fresh
Hestia install:

1. prints `==> first-run manager setup`, which reads as the start of success;
2. creates **no account, no admin group and no group-settings store**;
3. **exits 2, which the script never looks at** - `lazysite-hestia-deploy.sh`
   sets no `-e` and does not test the status of that command, so the run
   continues as though it had worked. The tool reports honestly; the caller
   discards the report;
4. never writes `auth/groups-settings.json`, the first-run sentinel - so **every
   subsequent deploy runs it again and fails again**, announcing first-run setup
   each time.

**The lesson is mine and it is the second time today.** Earlier I answered a
question about a fresh install by probing a command, and here I answered a
question about an exit code by reading the wrong process's status. Both times the
measurement was taken next to the thing rather than on it.

A site left in that state has no sysop at all. That is a coherent state by
SM659's own argument - "deploying with no accounts is fine" - but it is not the
state the installer says it produced.

# Where the `manager` accounts come from

The same line, before SM659. The old verb took **no `--user`** and defaulted to
an account literally called `manager`; the removal comment records exactly that:

> "This defaulted to an account literally called `manager`, with the password as
> a positional argument - a shared-secret ROLE account, as the DEFAULT path
> ... Role accounts are how people end up sharing a password, and the audit
> trail then says `manager` did everything."

Because the deploy script passes no `--user`, **every install bootstrapped by it
before SM659 got a `manager` account automatically**. Two installs both carrying
one is that, not a second account being created today.

So the two halves are one defect seen from either side of SM659: before it, the
installer silently created the role account SM659 forbids; after it, the
installer silently creates nothing.

# What would settle the remaining question

I have proved (from source, and reproduced here) that the current tool refuses
the command and that the current script calls it. What I have NOT measured is the
engine version on the release manager's two hosts. To confirm those `manager`
accounts are pre-SM659 residue rather than something still creating them:

- `cat VERSION` (or `lazysite --version`) on either host;
- whether `lazysite/auth/groups-settings.json` exists - if it does, first-run
  already completed, with the older tool;
- `lazysite-users.pl ... settings-get manager` - a `created_at` predating the
  upgrade, and no `created_by`, is the old default's signature.

If a `manager` account appears on an install created **after** those hosts were
upgraded, this filing is wrong about the cause and I want to know.

# The fix

1. **Stop calling a verb that cannot work, and stop claiming to do the thing.**
   `setup-sysop` requires a name by design, so a first-run bootstrap cannot
   create an account without inventing a username - which is exactly what SM659
   removed. The honest form is to say there are no accounts and print the command
   the operator runs, rather than announce a setup that did not happen.
2. **The exit status is already right; the CALLER must read it.** Nothing needs
   changing in the tool. What is missing is that
   `lazysite-hestia-deploy.sh` discards a non-zero status from a step it has just
   announced.
3. **A lint that every command named in a shipped installer or README exists in
   the dispatcher.** This is the [[feedback_a_declaration_the_code_ignores]]
   shape: SM659 updated `INSTALL-RUNBOOK.md` and missed
   `lazysite-hestia-deploy.sh` and `debian/lazysite-hestia.README.Debian:104`.
   The runbook being right is what hid it.
4. **Say something about the existing `manager` accounts** - `lazysite-check`
   naming a shared-looking role account is enough; nothing should rename or
   delete an account an operator may be signing in with. Recorded as not built.

# Related

SM659 (the rename, and the argument for requiring a name),
[[feedback_a_declaration_the_code_ignores]] (find every reader),
[[SM863]] (the other half of this command's output),
[[feedback_reproduce_before_blaming_the_host]] (reproduce in the environment the
report names).
