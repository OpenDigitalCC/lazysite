---
title: "SM329 - the site addressing did not reach the deployment it was built for"
subtitle: "SM321 keyed --domain to a registry that `provision` writes. The Hestia tarball path never runs provision, so the operator whose complaint prompted the fix was still typing full docroots."
brand: plain
status: shipped
status-note: "SHIPPED for 0.10.12. The CLI falls back to lazysite-hestia-list.sh when the registry is empty - the host's own authoritative discovery, which existed all along. The registry still wins when populated, so a deb install is unchanged. A non-root caller is told the lister needs root (it reads /usr/local/hestia/data/users) rather than 'no registered site named X', which would send them hunting for an entry that was never going to exist. FILED 2026-08-16, found by walking the operator through repairing edge on 0.10.11 and discovering the command I had just shipped did not apply to their host."
---

# What was wrong

SM321 gave `lazysite check` and `lazysite acl` a `--domain NAME` that resolves
the docroot and cgibin from the site registry at `/etc/lazysite/sites.d/`. It was
written to answer a specific complaint: *"this fix command is fragile and needs me
to know users and domains."*

**The registry is written by `provision`.** The Hestia tarball deployment never
runs it. `install.pl` says so in as many words:

> lazysite has no central site registry - the host knows the sites

So on the deployment this project actually uses - a tarball scp'd to `/tmp`,
unpacked, and run through `lazysite-hestia-update-all.sh` - `--domain` finds
nothing, and the operator is back to:

```bash
sudo perl /tmp/lazysite-0.10.11/tools/lazysite-cli.pl check \
     --docroot /home/<user>/web/<domain>/public_html \
     --cgibin  /home/<user>/web/<domain>/cgi-bin --fix
```

which is the command the whole filing existed to remove.

# The part that stings

**There were already two discovery mechanisms, and the CLI consulted the empty
one.** `lazysite-hestia-list.sh` discovers every site authoritatively - from the
Hestia web template rather than a marker file - and prints user, domain and
docroot. It is in the same tarball. SM321 read past it.

That is the same shape as SM318, filed a day earlier: two implementations of one
question, and the caller reaching for the one that could not answer. Writing that
filing did not stop me repeating it.

# How it was found

Not by a test, and not by review. By walking the operator through repairing edge,
writing out the command with `--domain`, and checking the claim before sending it
- at which point `install.pl`'s own comment said it would not work.

**A fix nobody could use is indistinguishable from no fix**, and the only thing
between shipping it and finding out was one check of an assumption I had not
questioned when I wrote it.

# The fix

When the registry is empty, ask the host. `lazysite-hestia-list.sh --plain
--template-only` gives `user`, `domain`, `docroot`; the cgibin is its sibling.

Two properties worth stating:

The registry still wins
: a deb install behaves exactly as before, and the fallback is reached only when
  there is nothing to read. Two sources, one order, no ambiguity.

Root is explained, not implied
: the lister reads `/usr/local/hestia/data/users`, so a non-root caller gets told
  that. Reporting "no registered site named X" would send them looking for a
  registry entry that was never going to exist - a true statement that misleads,
  which is the failure mode this project keeps filing.

# Related

SM321 (the addressing this completes), SM318 (two implementations of one
question, filed a day earlier), and `install.pl`, whose comment is the
authoritative statement that the registry is not universal.
