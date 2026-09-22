---
id: SM897
title: "SM897: the grouped rollout report counted phases as sites, printed the phase in the site name, and sorted every site list away from its finding"
subtitle: "SM889's first run against a real fleet, the 0.14.3 rollout: [123] for a warning that occurs at most once per site on 29 sites, 'probe cloudient.net, repair cloudient.net, repair cloudient.net' in a site list, and every 'sites:' line printed in a block after every '[N]' line. Plus the one per-site loop still printing raw - the ACL re-apply - which was most of the transcript."
brand: plain
standard-margins: true
status: shipped
raised: 2026-09-21
raised-by: release manager
area: installers
status-note: "SHIPPED - the fixed report ran against a real fleet. The 0.14.4 rollout (2026-09-22, 29 updated, 0 failed, repair and probe clean) printed the report this filing describes, and each of the four defects reads correctly in it: the `manager` account line reads [26] - a real count, three sites do not carry it - where the 0.14.3 run printed [123]; every site list names bare sites once each, with no phase word; every sites: line sits directly under its own finding; and the --reapply-acls phase is two lines ('re-applying access rules' and 're-applied on 29 site(s). Failed 0.') where it had been most of the transcript. Seventeen findings remain on the page and they are the estate's, not the report's - the front-end cache serving previously-public files on 18 sites plus two variants, statics answered without the engine on 20 (no --proxy: the SM283 template), the manager account on 26, undecided group capabilities in four spellings, and two probe cases named by site. Those are the sites agent's X1-X3 for the week. FOUR DEFECTS, for the record: (1) the count was lines not sites - check, repair-before, repair-after and probe each contributed one; (2) the phase-qualified run_quiet label was used as the site name; (3) the awk printed two lines per record and the pipeline sorted them apart; (4) the re-apply loop was the one per-site phase printing raw. The grouping is a function, group_findings - site is the label's last word, one line per (message, site) by sort -u, records in input order, nothing sorting the output - and t/tools/80 runs it as the script does with one case per defect and four sabotages. Bash resolves a function at call time; lint 50 caught it defined below its caller, and it moved. NOT CHANGED: what counts as a finding (NOISE_RE), and whether a rollout should print the remaining seventeen conditions at all - that is SM889's scope."
---

# What the 0.14.3 rollout printed

The first grouped report ([[SM889]]) against a real fleet. The rollout itself
was clean - 29 updated, 0 failed, repair 29 clean, probe 29 clean - and the
report was still most of a screen, for four reasons that are all the report's.

| Seen | Cause |
| --- | --- |
| `[123] [ warn ] this site has an account called "manager"` on 29 sites | the count was lines, not sites: check, repair-before, repair-after and probe each contributed one labelled line per site |
| `sites: … probe cloudient.net, repair cloudient.net, repair cloudient.net …` | `run_quiet`'s label is `"repair D"` / `"probe D"`, and the grouping used the label as the site |
| seventeen `[N] …` lines, then seventeen `sites: …` lines in a block below them | the awk printed two lines per record and the pipeline then `sort`ed all of them, so message lines and site lines sorted apart - the one thing a site list is for, pairing a list with its finding, was impossible |
| 21 × `No protected sections - nothing to re-apply.`, every site's `0 re-applied, 1 already in place …`, `Verify from OUTSIDE …`, twelve `[INFO] [acl-set]` log lines, and the @group advisory six times | the `--reapply-acls` loop was the one per-site phase not routed through `run_quiet` |

None of those lines is a finding of the rollout. The @group advisory is
`lazysite acl`'s interactive advice to a person setting a rule; a rollout
re-applying rules that already exist is not that person.

# The fix

`report_findings` hands the collected `label<TAB>message` lines to a
function of its own, `group_findings`:

1. the site is the **last word** of the label (`"repair D"` → `D`; a bare
   `D` is untouched);
2. one line per **(message, site)** - `sort -u` on those two keys is the
   dedupe, so a site seen in four phases is one site and the count is the
   number of sites;
3. records are printed **in input order** - by message, then site - and
   **nothing sorts the output**, so each `sites:` line follows its own
   finding.

The re-apply loop goes through `run_quiet "$d"` like every other per-site
phase: a genuine refusal still matches `NOISE_RE` and is collected, a failure
still prints its whole output, and the aggregate `re-applied on N site(s)`
line still says what happened.

# How it is held

`t/tools/80` extracts the **function body** and runs it as a function, fed the
same lines the script feeds it. The first draft passed the body to `bash -c`
bare and every case saw empty output - the body begins with `local`, which
is an error outside a function - so the harness now wraps it in a function of
the same name, which is also what "run it as the script runs it" means.

One case per defect: a site seen in four phases counts as one; the phase is
absent from every site name; each `sites:` line is the line after its
finding; the re-apply call is wrapped. Four sabotages - `sort` without `-u`,
the stripping `sed` replaced by `cat`, the trailing `| sort` restored, the
re-apply call unwrapped - each fail the file.

# What is not claimed

- **That the report is now the right length.** It is shorter by the four
  causes above; whether a 29-site rollout should print the remaining
  seventeen findings at all is a question about which conditions are the
  rollout's to report, and that is SM889's original scope, not this.
- **A run against a real fleet.** The fix is verified against the function
  with the lines the 0.14.3 run produced, not against a rollout.

# Related

[[SM889]] (the quiet report this is the residue of), [[SM345]] (why repair
and probe are per in-scope site, which is where the phase labels come from),
[[SM701]] (the original quiet contract).
