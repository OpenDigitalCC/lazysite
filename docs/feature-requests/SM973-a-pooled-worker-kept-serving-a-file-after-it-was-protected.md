---
id: SM973
title: "SM973: A pooled worker kept serving a file after it was protected"
subtitle: "The ACL store was read once per FastCGI worker, not once per request, so a protection added later did not reach a running worker."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-08
raised-by: the developer agent, found during SM944 S19 (moving the ACL copies)
area: security
status-note: "SHIPPED (PENDING): reset_request_state clears $ACL_MAP_CACHE, so every request reads acls.json. t/integration/110: in one worker, a file protected after the first request was served before, refused now."
---

# What was wrong

`$ACL_MAP_CACHE` holds the parsed `acls.json`. Its declaration says "parsed at
most once per request" (SM268 H13: a scan asks the read decision up to 200
times). Only the three readers that fill it ever assigned it.
`handle_one_request` runs `reset_request_state`, `_reset_units` and clears
`%ACCESS_REC` and `%AUTH_CONTEXT`, but not this.

Under the FastCGI pool (SM142), each worker serves up to
`LAZYSITE_FCGI_MAX_REQUESTS` requests (default 500). The first request to read
the store fixed the map for the rest of the worker's life:

- a file protected after that was still served to anonymous visitors;
- a reader removed from a list kept access;
- a store that failed to load once kept failing closed after it was repaired.

A plain CGI request is a fresh process each time, so only pooled workers were
affected.

# The fix

`reset_request_state` clears `$ACL_MAP_CACHE`. The store is still parsed at most
once per request, so the scan's 200 decisions cost one read.

The three other memos the processor's code keeps across requests were checked,
and each is safe:

- `_display_name_for` keys on the file's mtime and size.
- `_private_root` derives from the docroot, which a worker never changes.
- `update_registries`' "any templates?" probe concerns availability, not access.

# Evidence

t/integration/110 loads the processor once and serves each request through
`handle_one_request`, as the accept loop does:

- unlisted: the file is served;
- protected later: the same worker refuses it and redirects to log in;
- an unreadable store fails closed;
- once the store is readable again, the file is served.

With the reset removed, the second to fourth assertions fail. The finding's
probe is `tmp/sm944-s19-acl-cache-probe.pl`: the same worker gave 200 where a
fresh process gave 302.

# Related

[[SM268]], [[SM142]], [[SM944]].
