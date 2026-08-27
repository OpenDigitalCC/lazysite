---
title: "SM598: a handlers.conf path is built from an undefined docroot, and lands at the filesystem root"
subtitle: "Lazysite::Paths::lazysite_dir returns undef for an unset docroot, so _handlers_conf_path yields \"/forms/handlers.conf\" - an absolute path outside the site - and only a warning says so."
brand: plain
standard-margins: true
status: shipped
status-note: "SHIPPED in 0.11.3 (2026-08-27). BOTH CALLERS, and the WRITER was the sharper half: _handlers_conf_path now returns undef when lazysite_dir does, the reader logs and returns an empty list - so 'no docroot' is distinguishable from 'no handlers configured', which are not the same finding - and the writer REFUSES rather than make_path("/forms") at the filesystem root and writing a config file into it. That failed for want of permission on any sane host, which is luck rather than design. The test asserts directly that the path is never the root-anchored string the concatenation used to produce, because 'returns undef' and 'returns something wrong' are different failures and only one is caught by checking for undef. OBSERVED 2026-08-25 in the 0.10.33 release run, as a Perl warning emitted during the integration suite: 'Use of uninitialized value in concatenation (.) or string at lib/Lazysite/Manager/Plugins.pm line 666', which is `return _lz() . \"/forms/handlers.conf\"`. VERIFIED FROM THE CODE: _lz is Lazysite::Paths::lazysite_dir($DOCROOT), and lazysite_dir returns undef when the docroot is undefined or empty - a deliberate guard. The caller does not check it, so the concatenation produces `/forms/handlers.conf`: an ABSOLUTE path at the filesystem root rather than a path inside the site. Two readers use it, _parse_handlers_conf and the writer beside it. WHY IT IS NOT A CRISIS and is filed rather than fixed in the cut: on this host nothing exists at /forms/handlers.conf, so the read finds nothing and the surrounding code treats it as no handlers - the tests pass, which is exactly why it surfaced as a warning rather than a failure. WHY IT IS STILL WORTH FIXING: a path silently rooted at / is read from a place no site owns, and the failure mode is a form that reports no configured handlers for a reason no operator could deduce. The right fix is at the CALLER - a path built from an undefined root is a programming error and should refuse, not produce a path - and the same shape may exist wherever else _lz() is concatenated without a check, which is the part worth sweeping rather than patching one line. NOT IN 0.10.33: it emits a warning under a condition the suite reaches but no shipped surface has been shown to reach, and a sweep of every _lz() caller during a feature freeze is the wrong trade. NOT A BETA BLOCKER."
---

# What the warning says

```
Use of uninitialized value in concatenation (.) or string
  at lib/Lazysite/Manager/Plugins.pm line 666.
```

```perl
sub _lz { return Lazysite::Paths::lazysite_dir($DOCROOT) }

sub _handlers_conf_path {
    return _lz() . "/forms/handlers.conf";
}
```

`lazysite_dir` guards deliberately:

```perl
return undef unless defined $docroot && length $docroot;
```

so the guard is correct and the caller discards it.

# Why a warning is the wrong messenger

The value produced is `/forms/handlers.conf` - a real, absolute, readable
path that belongs to no site. Nothing refuses it. A reader finds no file,
reports no configured handlers, and an operator sees a form with no
delivery and no reason given.

# The shape worth sweeping

Every `_lz()` caller that concatenates without checking has this
property. The fix belongs at the caller - a path built from an undefined
root should refuse rather than produce a path - and the sweep is the work,
not the one line.
