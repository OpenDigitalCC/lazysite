---
id: SM899
title: "SM899: every SM892 refusal names a `lazysite` command that a tarball host does not have, and reports a refusal by design as a failed command"
subtitle: "0.14.3 W1 transcript, run by the operator from the unpacked tarball: provision on an existing site refused correctly and told them to type `lazysite upgrade …` — a command that answers 'command not found' on that host — then printed 'command failed (exit 2)' with the internal install.pl invocation. The signpost install.sh spells the invocation the way it was reached; the verbs do not. Plus two asks from the operator."
brand: plain
standard-margins: true
status: shipped
raised: 2026-09-22
raised-by: sites agent, from the operator's transcript
area: installers
status-note: "SHIPPED, all three defects and the ask. R1: the CLI knows how it was reached - basename($0) `lazysite` (the deb, or any link by that name) or `perl <absolute path>` otherwise - and passes it to install.pl as --invoked-as; declared_mode spells every one of its eight hints with it, so a tarball host is told `perl /tmp/lazysite-X/tools/lazysite-cli.pl upgrade --docroot ...` and a packaged one `lazysite upgrade ...`; refuse_root uses the same spelling. R2: the three declaring verbs (and demo) run the installer through run_installer, which forwards install.pl exit 2 (a refusal) and 3 (a channel skip) as they stand with nothing appended - the refusal IS the answer, and its exit code is now the operator's (2, where the CLI used to turn it into 1) - and hands anything else to run_or_fail, so a crash still reads `command failed (exit N)`. R3: starter/docs/install.md and UPGRADE.md say when --cgibin is needed (no registry entry: provisioned before the registry existed, or the registry directory not writable) and that the verb says so; _cgibin_for's refusal names --installdir as the other answer. THE ASK: --installdir DIR on provision, upgrade and reinstall stands for --docroot DIR/public_html --cgibin DIR/cgi-bin - the HestiaCP layout - and is refused alongside either option it stands for, because two statements of one path is how a wrong one goes unnoticed. t/tools/85 has one case per defect plus the crash discriminator and the --installdir pair; each was sabotaged (hint hardcoded, the forward removed, the derivation broken) and each case failed. NOT CHANGED: `lazysite channel|policy` still go through run_tool_per_site, whose exit-2 handling t/tools/86 relies on; and the CLI's own usage text still writes `lazysite VERB` - that is a reference, not a hint, and install.md tells the tarball reader how to spell it."
---

# The transcript

Run by the operator from `/tmp/lazysite-0.14.3`, against the test site.
W1a, `provision` on a site that exists:

```text
Installer: lazysite 0.14.3
lazysite: this site is ALREADY INSTALLED, at 0.14.3.
  provision is for a site that does not exist yet, so nothing was changed.
  To move it to 0.14.3:        lazysite upgrade --docroot /home/…/public_html
  To re-lay 0.14.3 as it ships:  lazysite reinstall --docroot /home/…/public_html
lazysite: command failed (exit 2): /usr/bin/perl /tmp/lazysite-0.14.3/install.pl --docroot … --cgibin … --mode provision
```

Refused, names upgrade and the version found, nothing written — the SM892
ruling holds. The operator's first question was *"where does the command
`lazysite` exist? its not in the path on tar installs."* Their words after
reading the hint: *"they forgot the tarball path."*

W1e, the old `install.sh` line, on the same host:

```text
  perl /tmp/lazysite-0.14.3/tools/lazysite-cli.pl provision --docroot DIR --cgibin DIR
```

The signpost spells it right. The verbs, one directory up, do not.

# Three defects

| Ref | Defect | Where |
| --- | --- | --- |
| R1 | The refusal hints name `lazysite …`, which does not exist on a tarball host. The CLI knows how it was invoked (`$0`); install.pl does not, and is the one printing the hint. Pass the caller's spelling down, or have the CLI render the hint. | `install.pl` `declared_mode` refusals; `tools/lazysite-cli.pl` |
| R2 | A refusal by design surfaces as *"command failed (exit 2)"* followed by the internal `install.pl … --mode provision` line. The refusal text above it already said everything; the failure line says the operator ran something wrong and points them at a file they did not type. An installer exit that IS a refusal should end with the refusal. | `tools/lazysite-cli.pl` `run_or_fail` at the `_install_argv` call sites |
| R3 | The install page's W1 table shows `upgrade --docroot D` alone. With no registry entry for the site — every tarball host — `_cgibin_for` fails and asks for `--cgibin`. Say when it is needed. | `starter/docs/install.md`, `UPGRADE.md` |

# One ask, parked

> "it would be easier to just specify installdir which can then assume the
> docroot and cgi paths."

On a HestiaCP host the pair is always `/home/<user>/web/<domain>/public_html`
and `…/cgi-bin`. `--installdir /home/<user>/web/<domain>`, or `--domain`
(which `channel` and `policy` already take), would remove the repeated path
and the chance of pairing a docroot with the wrong cgi-bin. A feature; parked
for after the no-development week, and worth doing then.

# What is not claimed

- That any verb did the wrong thing. Every refusal in the transcript refused
  correctly and changed nothing.
- R3 was not seen run; it is the operator's statement and it is consistent
  with the code.

# Related

[[SM892]] (the verbs), [[SM864]] / [[SM138]] (a shipped installer names a
command that exists — the same family, for a different reason).
