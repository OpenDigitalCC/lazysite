---
id: SM904
title: "SM904: a native form stores a non-ASCII value double-encoded - \"Hervé\" lands as \"HervÃ©\" in every destination"
subtitle: "Found on a live expo form on 2026-09-24: one real lead's name stored with UTF-8's two bytes read as two Latin-1 characters and encoded again. Reproduced on edge 0.14.4 both by a percent-encoded XHR and by the browser's own submit. The parse hands every field on as bytes; every destination - table, submissions file, mail, the thank-you page - encodes them again."
brand: plain
standard-margins: true
status: shipped
raised: 2026-09-24
raised-by: sites agent, from a live lead and two edge reproductions
area: forms
status-note: "SHIPPED. Reproduced first against the CGI with the new test (urlencoded %C3%A9 and a raw multipart body both stored as C3 83 C2 A9). THE MECHANISM: plugins/form-handler.pl parse_post decodes %XX to chr(hex) and takes a multipart text part raw, so every field reaches the handlers as BYTES with no UTF-8 flag; Lazysite::Handlers then writes the submissions copy through a >>:utf8 layer, hands the row to insert_row and the mail payload to encode_json, and the thank-you renders through a :utf8 STDOUT - four consumers, each treating a byte as a character and encoding it again. The API path was never affected because decode_json yields characters. THE FIX: one decode at the parse - _text() calls utf8::decode on each field name and each text value, in both branches, after field_value has done its BYTE-length check (MAX_FIELD_BYTES keeps meaning bytes); a body that is not valid UTF-8 is left as it was, which reads it as Latin-1 - the one reading that loses nothing. File parts stay raw. t/unit/forms/17 posts to the CGI both ways and reads the store back; a plain value and a Latin-1 body are the controls. Two sabotages (the urlencoded decode removed, the multipart decode removed) each failed the test. NOT CHANGED: the rows already stored mangled on live - a data repair on one site is the operator's, and the fix is not retroactive; the sites agent's filing names the row."
---

# What was measured

| Where | Sent | Stored |
| --- | --- | --- |
| live, `odcc_leads` row 8 (2026-09-24T16:14:49Z) | a name ending *Hervé* | `HervÃ©` |
| edge, sync XHR, `application/x-www-form-urlencoded` | `Herv%C3%A9%20%C3%9Cml%C3%A4ut` | `HervÃ© Ã\x9cmlÃ¤ut` |
| edge, the form filled in the DOM and `requestSubmit()` | the browser's own encoding | the same |
| edge, `data-row-save` with a JSON body | `Ostrów` | `Ostrów` |

Two client paths, one result; the API path clean. So the fault is between
the POST body and the handler's write.

# The mechanism, read from the code

`plugins/form-handler.pl` `parse_post`:

```perl
$v =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/ge;     # urlencoded: one byte per %XX
_field_add( \%form, $name, field_value( $name, $body ) );   # multipart: raw
```

Neither branch decodes. `Hervé` arrives as five characters `H e r v \xC3
\xA9` - six bytes as six code points - and is handed on. Then:

- `Lazysite::Handlers::_to_file` opens the submissions store `>>:utf8` and
  prints `encode_json(\%rec)`: each of the two "characters" is encoded as
  UTF-8 again → `C3 83 C2 A9` on disk.
- `_table_row` passes the same string to `insert_row`, whose writer encodes
  it the same way.
- `_to_smtp` hands `encode_json(\%payload)` to the SMTP script.
- the thank-you renders through `binmode STDOUT, ':utf8'`.

The API path (`data-row-save`) reads a JSON body with `decode_json`, which
yields characters, so it was never affected - which is why the sites agent's
addendum found it clean.

# The fix

One decode, at the parse, in both branches: after `field_value` (whose
length check counts bytes, as its name says) each field name and text value
goes through `utf8::decode`. A body that is not valid UTF-8 is left as it
was - that reads it as Latin-1, which is what a Latin-1 body is. File parts
stay raw.

# What is NOT claimed

- That rows already stored mangled are repaired. The fix is not retroactive.
- Anything about the four destinations' own encoding, which is right once
  they are given characters.

# Related

[[SM842]] (handlers and delivery), [[SM401]] (repeated keys in the same
parse), [[SM539]] (the multipart branch), [[SM856]] (a form field carries a
value).
