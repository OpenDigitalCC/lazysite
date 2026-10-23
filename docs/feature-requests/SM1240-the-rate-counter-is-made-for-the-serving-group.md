---
id: SM1240
title: "SM1240: the sign-in rate counter is made for the serving group"
subtitle: "The login rate limiter created its counter 0600. On two production sites it was owned by the site user, the CGI could not open it, and every attempt was allowed. The counter is now created 0660 in the auth directory's group, under any umask."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-22
raised-by: "the release manager, from the 0.16.0 rollout findings"
area: auth
status-note: "SHIPPED (0.16.1) on n725: Lazysite::Auth::LoginRate creates .login-rate.db 0660 under a umask that keeps both group bits, sets the auth directory's group on a new counter, and gives group access back to a counter it owns. t/unit/auth/73."
---

# What happened

The 0.16.0 rollout found `lazysite/auth/.login-rate.db` at 0600 on two production
sites, owned by the site user in group www-data. The CGI runs as www-data and could
not open it. The limiter fails open (SM798), so every sign-in attempt was allowed. The
auth log said so on each attempt, and `lazysite check` reported it (its --fix chowns
the file and sets 0660).

# The cause

The counter has one creator: the `tie` in `Lazysite::Auth::LoginRate::check_login_rate`,
which asked for mode 0600. Four callers count against it:

- the sign-in CGI (`lazysite-auth.pl`);
- the member's account page (`Manager::Account`, through the manager API or the
  control API);
- the Odoo sign-in (`Lazysite::Odoo::sign_in`, from `lazysite-odoo.pl` or the runtime's
  Odoo endpoint).

These do not all run as one unix user, and 0600 closes the file to every identity but
its owner. A counter the CGI made 0600 and an ownership pass then gave to the site user
(the Hestia deploy's `chown -R "$U":www-data`, or a root `check --fix` chown) is in the
same state. So is one first made by a process running as the site user, in the setgid
auth directory. The mode was also filtered by the caller's umask: the runtime runs
under 077 and a shell under 022.

# What shipped

- The counter is created 0660. The `tie` runs under a umask that clears only the bits
  0660 does not carry, and the caller's umask is put back afterwards.
- A new counter takes the auth directory's group. A setgid directory gives it already;
  otherwise the limiter sets it. This is best effort, because a process can only give a
  file to a group it belongs to.
- A counter this process owns that has lost group read or write gets 0660 back, as the
  audit log does (Audit.pm). A counter owned by another user is left alone; the doctor
  repairs that, as before.

The fail-open direction is unchanged.

# Tests

t/unit/auth/73 runs the real limiter:

- under umasks 077, 022, 027 and 0002 the new counter is 0660;
- the caller's umask is restored;
- in an auth directory set to a second group without setgid, the counter takes the
  directory's group;
- a 0600 counter it owns is 0660 after the next attempt;
- it still refuses the sixth attempt in a window.

With the change reverted, six of its assertions fail.

# Not done

- **Fail closed or open.** A limiter that cannot open its counter still allows the
  attempt. Whether it should refuse sign-in instead is a security product decision for
  the release manager, and the report for this change sets out the trade-off.
