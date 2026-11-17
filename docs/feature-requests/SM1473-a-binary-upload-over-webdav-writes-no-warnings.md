---
id: SM1473
title: "SM1473: a binary upload over WebDAV writes no warnings"
subtitle: "A PUT of an image, PDF or archive was decoded as UTF-8 twice and Perl warned once per bad byte sequence, filling the error log."
brand: plain
standard-margins: true
status: shipped
raised: 2026-11-17
raised-by: "the release manager"
area: webdav
status-note: "SHIPPED (0.17.2, a stable patch of 0.17.1): only pages, form configs and nav files are read after a WebDAV PUT, raw and then as the processor reads them; a binary upload writes no warnings. Register entry confirmed (ruling 273)."
---

# What happened

A production web server's error log grew by hundreds of megabytes of lines like

```
UTF-8 "\x99" does not map to Unicode at .../cgi-bin/lazysite-dav.pl line 760.
```

one per bad byte sequence, after files were uploaded over WebDAV.

# Why

After the streamed write, the PUT path of `lazysite-dav.pl` ran its content checks on every
uploaded file, not only on pages. Two of them opened the temporary file through a
`<:encoding(UTF-8)` layer and read it whole: the page-parse guard (SM729, first shipped in
v0.11.11) and the address-profile check (n812, v0.16.11). A binary upload was decoded as
UTF-8 and Perl warned once per invalid sequence, and the whole file was read and decoded twice,
a CPU and memory cost as well. The form-config and navigation checks read through the same
layer.

Checked and clear: the manager and MCP save path (`Manager::Files::action_save_binary`, the
choke point `_content_write_refusal`) reads through `text_as_processor_reads` and
`invalid_utf8_offset` (`Encode::FB_QUIET`), which never warn, and no other file under `lib/`,
the manager API or MCP reads through `:encoding(UTF-8)`.

# The request

R1
: Each PUT check runs only on the files it judges. A page (`.md`) is read once, raw, then as
  the processor reads it (`Manager::Common::text_as_processor_reads`, as the SM976 Q15f
  block already did), and that one text feeds the page-parse, address-profile and form-binding
  refusals. A form config and a navigation file are read the same way. A file that is none of
  these is not read after the write. No decode layer is used, so no warning is emitted.

R2
: The refusals are unchanged: an unparseable page, a page naming a missing address profile,
  a page that is not valid UTF-8, a form config with bad targets and a navigation file with a
  script address are refused as before.

# Status

Built, awaiting the release manager. Test: t/tools/750 (a small and a 256 KiB binary with
invalid UTF-8 land with no "does not map to Unicode" line; a page with invalid UTF-8 is still
refused with 415; an unparseable page is still refused). It fails on the code before the fix.
Register entry in docs/SECURITY.md (drafted, for the release manager's confirmation): what is refused is unchanged, only how the text is read. Ships in the 0.17.2 stable patch (ruling 270).
