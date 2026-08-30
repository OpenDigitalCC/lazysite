---
id: SM700
title: The data endpoint emitted characters as bytes, so every accent became a black diamond
raised: 2026-08-30
raised-by: edge/site-testing agent
area: data
status: shipped
status-note: "SHIPPED in 0.11.8. On familyhq a Swiss holiday rendered as 'Je?ne f?d?ral' - U+FFFD for every accent. Reported before and still present, because the earlier attempt was aimed at ingest and storage, which the field then MEASURED as correct UTF-8 through the control API. The two endpoints read the same rows and diverged at one step: lazysite-data.pl encoded with JSON::PP->new->...->encode and no ->utf8, on a STDOUT with no layer, so each codepoint went out as one byte while the header promised charset=utf-8. Fixed both directions - the request body had the inverse defect and would have STORED double-encoded text - plus the Content-Length, which was right only because the bug emitted one byte per character."
---

# The report, and why it had survived one fix already

An operator saw `Je?ne f?d?ral` where `Jeûne fédéral` belonged: a replacement
character for each accent, with ASCII and even the en dash fine. It had been
reported before and was still there.

The field agent's diagnosis is what made this quick, and the valuable half was
the **elimination**: reading the same row through the control API returned
`C3 BB` and `C3 A9` - valid UTF-8. So ingest, the SQLite store and the control
API were all correct, and any fix aimed at those was aimed at a layer that was
never wrong.

# The chain

1. `Connect.pm` opens SQLite with `sqlite_unicode => 1`, so a TEXT column comes
   back as a **character** string - `û` is one character, U+00FB.
2. `JSON::PP->new->canonical->encode` without `->utf8` returns JSON as
   **characters**, not bytes.
3. `print` to a STDOUT with no encoding layer writes each codepoint as one byte:
   U+00FB becomes `0xFB`.
4. The header says `charset=utf-8`. `0xFB` is not a valid UTF-8 start, so the
   browser substitutes U+FFFD.

The control API never had this because it uses `encode_json` - UTF-8 by
definition - with STDOUT in binmode.

# Three things fixed, not one

**The response.** `->utf8` added, so the body is bytes.

**The request.** `read()` returns bytes and they were being decoded with no
`->utf8`, treating each byte as a codepoint. A posted accent would arrive as two
characters and be **stored double-encoded**. The read path made the mojibake
visible; this one would have written it, and it was one endpoint away from being
a data-corruption bug rather than a rendering one.

**The Content-Length.** It was `length()` of the character string, and it was
correct *only because of the bug* - one byte per character. Fixing the encoding
alone would have under-reported the byte length and truncated every response
carrying an accent, turning a cosmetic fault into a broken one. The length is
now taken after encoding.

`binmode STDOUT` added as well: relying on the absence of an encoding layer
works until something adds one.

# The same shape elsewhere

`JSON::PP->new->...->encode` without `->utf8` also appears in `lazysite-dav.pl`
(writing a record to a file), `lazysite-processor.pl`, `tools/lazysite-acl.pl`,
`tools/lazysite-site.pl` and `tools/lazysite-domains.pl`. Those are file writes
and CLI output rather than HTTP responses with a charset header, so none has the
browser-facing failure this had - but each would corrupt non-ASCII the same way
if its output is later read as UTF-8. **Not changed here**, because a CLI's
output encoding is its own decision and changing six of them blind is how a
one-line fix becomes an incident. Worth a pass of its own.

# Related

The field agent could not capture the live response bytes - the table is private
and the endpoint needs a family session, which a partner token is not. The
diagnosis stood on measured storage bytes, the code path, the control-API
contrast and an exact symptom match, and it was right. The test added here
asserts at the byte level what they could not reach.
