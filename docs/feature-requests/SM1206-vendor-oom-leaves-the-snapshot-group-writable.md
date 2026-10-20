---
id: SM1206
title: "SM1206: vendor-oom.sh leaves the snapshot group-writable"
subtitle: "Vendoring OOM 0.36 in the shared checkout left t/vendor/oom directories 2755 and files 644, so the release manager's git reset --hard failed with permission denied. The tool now writes group-writable, whatever the caller's umask."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-20
raised-by: "the release manager, after vendoring OOM 0.36 on 2026-10-19"
area: tools
status-note: "SHIPPED (PENDING) on n694: tools/vendor-oom.sh runs under umask 002 and sets directories 0775 and files 0664 (setgid kept from the parent). t/tools/188 runs it under umask 022 into a setgid scratch parent."
---

# What happened

On 2026-10-19 `tools/vendor-oom.sh` vendored OOM 0.36 into the shared checkout and
ended with `find "$DEST" -type d -exec chmod 0755` and `-type f chmod 0644`. Another
user in the same group, the release manager, then ran `git reset --hard` and got
"unable to unlink old 't/vendor/oom/MANIFEST': Permission denied" and "cannot create
directory at 't/vendor/oom/behaviours/account.payment.register'".

# What shipped

- The script sets `umask 002`, so the MANIFEST and every copy are group-writable.
- The final modes are 0775 for directories and the tool, 0664 for files. A numeric
  chmod does not clear a directory's setgid bit, and `mkdir` takes it from the parent.
- `t/tools/188` runs the tool under umask 022 into a scratch destination whose parent
  is setgid and group-writable, and fails for any directory or file that lacks
  group write, or any directory that lost setgid.

# Not done

- Files left 2755/644 by earlier runs are not touched; the next vendoring replaces them.
