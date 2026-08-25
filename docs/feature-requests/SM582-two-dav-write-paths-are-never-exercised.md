---
title: "SM582: two DAV write paths are never exercised, and sabotage is what proved it"
subtitle: "Breaking the streaming size ceiling and the entry-removal failure return changed no test result. Both live on the WebDAV write surface, which is where a silent regression would hurt most."
brand: plain
standard-margins: true
status: candidate
status-note: "FOUND 2026-08-25 during the SM516 cleanup wave: while sabotage-verifying the front-door extractions, breaking two paths produced NO test failure. (1) _stream_body's streaming size ceiling never fires under the suite - every test sends a Content-Length, so the pre-read gate answers 413 first and the streaming ceiling is unreachable in testing. (2) _remove_entry's failure return is never observed - no test makes an entry removal fail. Both are on lazysite-dav.pl's write path. This is not a defect in the code; it is an absence of evidence about the code, which the cleanup surfaced because sabotage asks a question no passing test asks: would anyone notice? PLANNED for 0.10.33: a chunked PUT with no Content-Length that exceeds the ceiling must be refused with the streaming refusal (not the pre-read one), and a removal made to fail (unwritable parent, per SM284's own rig) must return its failure rather than reporting success."
---

# Why an unexercised path matters here

SM284 exists because a MOVE out of an unwritable directory once reported
201 while leaving both copies in place - a failure that returned success.
These two paths are the same shape and nothing would catch a repeat.

# Proving tests

- A chunked PUT without `Content-Length`, larger than the ceiling, is
  refused by the streaming gate; assert the refusal names the size limit
  and that no partial file remains.
- An entry removal that cannot succeed returns the failure (the SM284
  rig makes the parent unwritable); assert the DAV answers a 5xx and the
  entry is still there.
