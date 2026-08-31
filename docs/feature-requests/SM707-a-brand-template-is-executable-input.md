---
id: SM707
title: A brand template is executable input, so the manager does not accept one
raised: 2026-08-31
raised-by: engine (found while answering "how do I upload my brands?")
area: security
status: candidate
---

# What happened

The Branded PDF plugin creates `lazysite/brands/` and tells the operator to
manage it "on the Files page like any other folder". The Files page answered
**Path is blocked**: the whole `lazysite/` tree is off-limits to the file
editor except for a short carve-out list, and brands was not on it. So the
instruction was false and the folder invisible - reported by the release
manager, who could see neither the folder nor a way to put a brand in it.

`lazysite/brands/` is now carved out, so a logo, a font or a colour file can be
managed there like any other content. That much is settled and shipped.

# The part that is NOT settled

A brand also holds a **pandoc template**, and a template is not an asset. Its
text is handed to xelatex at render time, so `\input{/etc/passwd}` inside one
is read by the CGI user and lands in a PDF the uploader can download.

Accepting template uploads through the manager would therefore convert
`manage_content` - today, the authority to write pages - into "read any file
this server can read". That is a different grant, and not one the Files page
is entitled to hand out on its own.

**Measured, not assumed:** `md-to-pdf` invokes pandoc with
`--pdf-engine=xelatex` and never passes `-shell-escape`, so this is a file
READ and not command execution. The line is drawn there for that reason.

So `.tex`, `.latex`, `.sty`, `.cls` and `.lua` under `lazysite/brands/` are
refused by `is_blocked_path`, and templates arrive the way they always have:
placed on the server by somebody who already holds that authority.

# The question for the release manager

Should the manager ever accept a template, and if so under what authority?

Three shapes, none built:

1. **Never.** Templates are a server-side install. Simple, and the operator of
   a hosted site cannot brand their own PDFs without asking their host.
2. **A capability of its own** - `manage_pdf_templates`, held by nobody by
   default. The grant then says what it is, and an operator can be given it
   deliberately by someone who understands what they are handing over.
3. **A vetted subset.** Accept a template but refuse the constructs that read
   files (`\input`, `\include`, `\openin`, `\usepackage` of arbitrary paths).
   A denylist over a Turing-complete language is a poor bet, and this option is
   listed to be argued against rather than chosen.

Option 2 is the one worth building if the answer is not "never": it names the
authority instead of hiding it inside another one.

# Related

[[SM694]] (the converter and its boundary), [[SM706]] (parts and caching).
