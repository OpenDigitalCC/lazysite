#!/usr/bin/perl
# P5 (WORK-PLAN-0154): a template tag in a page body reaches TT as written.
#
# The body is converted from Markdown BEFORE the template pass, so every
# `[% ... %]` went through the converter as prose. Reported from a 1,745-post
# site: `[% IF a && b %]` logged "template error, using raw content ...
# unexpected token (&)" and the page showed its own source - the tag reached
# TT as `[% IF a &amp;&amp; b %]`. `<` met the same escape, and `*` or `_`
# could pair into emphasis across two tags.
#
# convert_md lifts each tag out and puts it back as written. Text OUTSIDE the
# tags is escaped exactly as before, and a tag shown in code - a code span, an
# indented block, a fenced block - is still shown, escaped, not run.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(setup_minimal_site run_processor site_tempdir);

sub spit { my ( $p, $t ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh; return }

my $docroot = site_tempdir();
setup_minimal_site($docroot);

spit( "$docroot/ops.md", <<'MD' );
---
title: Ops
---

[% a = 1; b = 1; n = 3 %]
And: [% IF a && b %]AND-RAN[% END %]. Or: [% IF 0 || b %]OR-RAN[% END %].
Less: [% IF n < 5 %]LT-RAN[% END %]. Times: [% n * 2 %]x and [% n * 3 %]y.

Prose keeps its escapes: Tom & Jerry, a && b, x < y.

<div>[% IF a && b %]IN-HTML-RAN[% END %]</div>

Span: `[% IF a && b %]`

    [% IF n < 5 && a %]indented[% END %]

```
[% IF a && b %]fenced[% END %]
```
MD

my $out = run_processor( $docroot, '/ops' ) // '';
my ( undef, $body ) = split /\r?\n\r?\n/, $out, 2;
$body //= '';
my ($main) = $body =~ m{<main>(.*)</main>}s;
$main //= $body;

subtest 'a tag with && || < or * runs' => sub {
    ( my $prose = $main ) =~ s{<pre>.*?</pre>|<code>.*?</code>}{}gs;
    unlike( $prose, qr/\[%/, 'no tag is left outside code: the template parsed' )
        or diag($main);
    like( $main, qr/And: AND-RAN\./,     '&& runs' );
    like( $main, qr/Or: OR-RAN\./,       '|| runs' );
    like( $main, qr/Less: LT-RAN\./,     '< runs' );
    like( $main, qr/Times: 6x and 9y\./, 'two tags holding * are not paired into emphasis' );
    like( $main, qr/IN-HTML-RAN/,        'inside an HTML block too' );
};

subtest 'a line that opens with a tag keeps its shape' => sub {
    # A loop line shaped `[..]A:[..]:b=[..]` is a reference-link definition to
    # the converter unless its tags read as tags - with spaces, as written. An
    # earlier placeholder without them made this line vanish (t/integration/39).
    spit( "$docroot/lead.md",
        "---\ntitle: Lead\n---\n[% FOREACH x IN [1, 2] %]ROW:[% x %]:n=[% x * 10 %]\n[% END %]\n" );
    my $o = run_processor( $docroot, '/lead' ) // '';
    like( $o, qr/ROW:1:n=10/, 'the first row' );
    like( $o, qr/ROW:2:n=20/, 'and the second' );
};

subtest 'text outside the tags is escaped as before' => sub {
    like( $main, qr/Tom &amp; Jerry, a &amp;&amp; b, x &lt; y\./, 'prose & and < are escaped' );
};

subtest 'a tag shown in code is shown, escaped, and not run' => sub {
    like( $main, qr{<code>\[% IF a &amp;&amp; b %\]</code>}, 'a code span' );
    like( $main, qr{<pre><code>\[% IF n &lt; 5 &amp;&amp; a %\]indented\[% END %\]}, 'an indented block' );
    like( $main, qr{<pre><code[^>]*>\[% IF a &amp;&amp; b %\]fenced\[% END %\]}, 'a fenced block' );
};

done_testing;
