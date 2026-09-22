---
id: SM899
title: "SM899: every SM892 refusal names a `lazysite` command that a tarball host does not have, and reports a refusal by design as a failed command"
subtitle: "0.14.3 W1 transcript, run by the operator from the unpacked tarball: provision on an existing site refused correctly and told them to type `lazysite upgrade …` — a command that answers 'command not found' on that host — then printed 'command failed (exit 2)' with the internal install.pl invocation. The signpost install.sh spells the invocation the way it was reached; the verbs do not. Plus two asks from the operator."
brand: plain
standard-margins: true
status: candidate
raised: 2026-09-22
raised-by: sites agent, from the operator's transcript
area: installers
status-note: "FILED, not built - a week with no feature work, and the two defect halves are small enough to go into the next cut with SM898. THREE DEFECTS, all in what the verbs SAY, none in what they do: (1) install.pl's refusals hint `lazysite upgrade --docroot …` and `lazysite reinstall --docroot …`; on a tarball host there is no `lazysite` on PATH and the operator reached the verb as `perl /tmp/lazysite-0.14.3/tools/lazysite-cli.pl`. install.sh already spells its hints the way it was reached; the verbs should too - the CLI knows $0, and install.pl can be told the caller's spelling. (2) run_or_fail reports a by-design refusal as 'command failed (exit 2): /usr/bin/perl …/install.pl --docroot … --mode provision' - a refusal is not a failed command, and install.pl is not something the operator typed or should be pointed at; a refusal exit from the installer should surface as the refusal alone. (3) The doc's W1 table shows `upgrade --docroot D` alone; on a host with no registry entry for the site, upgrade needs --cgibin too (the operator's statement, not seen run; consistent with _cgibin_for). The doc should say when --cgibin is needed. ONE ASK, parked as a feature for after the week: `--installdir /home/<user>/web/<domain>` (or `--domain`, which channel and policy already take) deriving docroot and cgi-bin on a Hestia layout, so the pair is never mistyped."
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
