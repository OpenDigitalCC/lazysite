---
title: "SM517: downloads honour the carve-out"
subtitle: "SM268 H4 put nav.conf and the submission store behind a capability on every file verb the gate knew about. The two download verbs were not on its list, so the same files left by a different door."
brand: plain
standard-margins: true
status: shipped
status-note: "FOUND 2026-08-25 by the manager-api structural review, proven by probe tmp/mapi-probe-download-carveout.t on the 62-carveout-caps rig: on a SECURED site an account holding manage_content alone was refused `read` of lazysite/forms/submissions/contact.jsonl and of lazysite/nav.conf, yet `file-download` of either path returned 200 with the body and `file-zip-download?paths=...` returned a zip carrying both. ROOT CAUSE: the H4 gate keys on %file_surface, which listed read, list, preview and git-show but neither download verb - the SM418 defect (file-upload keyed wrong) in its read-side form - and the zip action re-parses `paths=` from QUERY_STRING itself, so $path was `/` and no gate ever saw the list; t/lint/14 carried both verbs on its reviewed-read allowlist, which is why nothing failed. SHIPPED 0.10.32 (the beta build): both download verbs are 'read' in %file_surface, and for the zip the pipeline gate runs carveout_refusal over every requested path - one governed path the caller may not read refuses the WHOLE zip, audited, naming the path and the capability, as `read` of that path would. t/unit/manager/62-carveout-caps.t drives both verbs on the same rig (the body lacks SUBMISSION-BODY-MARKER and NAV-BODY-MARKER, the refusal names the capability, an ordinary page still downloads and zips) and was red before the fix; t/lint/14 now asserts every path-bearing action in %SCOPED_ACTION is keyed in %file_surface, so the class cannot recur by omission."
---

# The defect

`read` of the submission store said *it needs the read_submissions or
manage_forms capability*. `file-download` of the same path, by the same
account, served the file. `file-zip-download` served it inside an
archive, with `nav.conf` beside it. Same file, same caller, three verbs,
one answer wrong twice.

# Why

The SM268 H4 gate runs in the request pipeline over `%file_surface`,
a map from the dispatched action name to `read` or `write`. An action
absent from the map is invisible to the gate. Both download verbs were
absent - SM418 found exactly this shape for `file-upload`, keyed under
a name the dispatcher never used, and fixed that one entry.

The zip has a second cause: it collects `paths=` from the query string
inside the action, so the pipeline's `$path` is `/` and carries nothing
to gate.

# The fix

- `file-download` and `file-zip-download` are `read` in `%file_surface`.
- For the zip the gate collects the requested paths itself
  (`collect_zip_paths`, now exported) and runs `carveout_refusal` over
  each.
- One governed path the caller may not read refuses the whole zip. The
  zip's own convention is to skip a path it may not read and log it;
  that convention is silent to the caller and would hand back an
  archive that quietly lacked a file. H4's contract is a refusal that
  names the path and the capability, and the download gets the same
  refusal `read` gives.

# Proof

`t/unit/manager/62-carveout-caps.t` - the manage_content-only account
on the secured site: the download body lacks both markers, the refusal
names `read_submissions` / `manage_nav`, the zip refusal names the path
and the capability, an ordinary page still downloads and zips, and
`read_submissions` once granted reaches the download. Confirmed red
before the fix and red again with the fix reverted.

`t/lint/14` - every path-bearing action in `%SCOPED_ACTION` is keyed in
`%file_surface`; the two verbs that carry no path are the only
exemptions.
