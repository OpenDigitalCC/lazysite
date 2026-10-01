#!/usr/bin/perl
# SM931: a protected code span inside a TT loop published the engine's own
# placeholder text on a customer-facing page.
#
# MEASURED ON A LIVE PAGE: 27 rows from a `json:` file, each with a token in an
# inline code span. 22 cells carried the literal string `CODEBLOCK_0_END` and 5
# carried the author's unrendered `[% ... %]`. The body is protected ONCE before TT;
# TT duplicated the placeholder once per iteration; the restore was a substitution
# without /g, so exactly one copy came back.
#
# THE REPORT PROPOSED `/g` AND THE RULING REFUSED IT, because the loop was the
# problem rather than the flag: each iteration rescanned text earlier iterations had
# inserted, so a protected block whose own text contains a later placeholder gets
# that text substituted too. The realistic instance is this project's own
# documentation of this mechanism, and it is the third subtest below - the one case
# `/g` fails and one pass passes.
#
# WHAT THIS DOES NOT FIX, asserted so nobody reads the fix as more than it is:
# inside a loop a code span cannot be both protected from TT and expanded by it.
# Protecting it is the right default, so the author sees their own `[% ... %]`
# repeated - which they can act on - and the engine's internals never reach the page.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(setup_minimal_site run_processor site_tempdir);

# site_tempdir, not a bare tempdir: t/lint/118 holds that a docroot handed to the
# engine sits a level down, so the engine never writes into the tempdir root.
my $docroot = site_tempdir();
setup_minimal_site($docroot);

sub page {
    my ( $name, $body ) = @_;
    open my $fh, '>', "$docroot/$name.md" or die $!;
    print {$fh} $body;
    close $fh;
    return;
}

# --- the live shape: a code span inside a FOREACH ----------------------------
subtest 'a code span in a loop never publishes the engine placeholder' => sub {
    page( 'rows', <<'MD' );
---
title: Rows
nocache: true
---

<table>
[% FOREACH p IN [ { t => 'alpha' }, { t => 'beta' }, { t => 'gamma' } ] %]
<tr><td><code>[% p.t %]</code></td></tr>
[% END %]
</table>
MD
    my $out = run_processor( $docroot, '/rows' );
    unlike( $out, qr/CODEBLOCK_/,
        'no internal placeholder reaches the page - the whole point of the filing' )
        or diag('This is the string that appeared in 22 customer-facing cells.');

    # Three rows rendered, each carrying the author's own unrendered directive. That
    # is the honest outcome, not a success: the span is protected from TT, so it
    # cannot also be expanded by it.
    my $spans = () = $out =~ m{<code>\[%\s*p\.t\s*%\]</code>}g;
    is( $spans, 3,
        'every row carries the author\'s own text, which they can see and act on' );
};

# --- what the report\'s /g would have broken ---------------------------------
subtest 'a protected block whose own text names a later placeholder' => sub {
    # Two spans. The FIRST contains the literal text of the SECOND one's
    # placeholder - which is what a page documenting this mechanism looks like.
    # Under `/g` the first restore rewrites that text and the page loses it.
    page( 'selfref', <<'MD' );
---
title: Self reference
nocache: true
---

<p>First: <code>CODEBLOCK_1_END</code></p>
<p>Second: <code>second</code></p>
MD
    my $out = run_processor( $docroot, '/selfref' );
    like( $out, qr{<code>CODEBLOCK_1_END</code>},
        'the first span keeps its own text, verbatim' )
        or diag( 'The report\'s `/g` substitutes the second block into this span. '
            . 'One pass does not, because the engine resumes after inserted text.' );
    like( $out, qr{<code>second</code>}, 'and the second span is restored' );
};

subtest 'a placeholder with no block of its own is left alone' => sub {
    # No code spans at all, so @code_blocks is empty and this string is just prose.
    # It must survive rather than being replaced with the empty string.
    page( 'orphan', <<'MD' );
---
title: Orphan
nocache: true
---

The engine's internal marker looks like CODEBLOCK_7_END when it leaks.
MD
    my $out = run_processor( $docroot, '/orphan' );
    like( $out, qr/CODEBLOCK_7_END/,
        'an author writing the marker in prose keeps it' )
        or diag( 'Replacing an unmatched placeholder with the empty string would '
            . 'also hide a genuine leak from the person reading the page.' );
};

# --- the claim in the report that did NOT stand, kept as a test -------------
subtest 'a span containing regex metacharacters passes through unchanged' => sub {
    # The report said `$code_blocks[$i]` on the replacement side put a `$` or a
    # backslash "at the mercy of that interpolation". The filing measured that false
    # and it stays false under the repair: the replacement is interpolated once and
    # the result is not re-parsed.
    page( 'meta', <<'MD' );
---
title: Meta
nocache: true
---

<p>One: <code>s/(\w+)/$1/g</code></p>
<p>Two: <code>C:\path\new\test</code></p>
MD
    my $out = run_processor( $docroot, '/meta' );
    # index() with SINGLE-quoted needles, not qr//: a `qr{...$1...}` interpolates
    # $1 away before the match ever runs, which is how the first version of this
    # test "passed" the thing it meant to check - the same class of mistake the
    # report made about the replacement side.
    cmp_ok( index( $out, 's/(\w+)/$1/g' ), '>=', 0,
        'a substitution written with $1 survives' );
    cmp_ok( index( $out, 'C:\path\new\test' ), '>=', 0,
        'and a Windows path with backslashes' );
};

# --- ITEM 2 OF THE RULING: SAY SO WHEN IT HAPPENS ---------------------------
# Without this the author's only clue is their own unrendered text in the page, and
# the filing says plainly how it was found the first time: by reading rendered HTML.
# run_processor discards STDERR, so this one runs the processor itself to read the
# log line - a helper that threw the evidence away would make the check untestable.
subtest 'the log says the render multiplied a protected block' => sub {
    page( 'warned', <<'MD' );
---
title: Warned
nocache: true
---

[% FOREACH p IN [ { t => 'one' }, { t => 'two' } ] %]<p><code>[% p.t %]</code></p>
[% END %]
MD
    my $err  = "$docroot/stderr.txt";
    my $proc = TestHelper::processor_path();
    local %ENV = %ENV;
    $ENV{DOCUMENT_ROOT}  = $docroot;
    $ENV{REDIRECT_URL}   = '/warned';
    $ENV{REQUEST_METHOD} = 'GET';
    $ENV{QUERY_STRING}   = '';
    qx($^X \Q$proc\E 2>\Q$err\E);

    open my $fh, '<', $err or die "$err: $!";
    my $log = do { local $/; <$fh> };
    close $fh;

    like( $log, qr/\[WARN\]/, 'a WARN is logged, not an INFO nobody filters for' );
    like( $log, qr/multiplied a protected code block/,
        'and it says what happened in words an operator can act on' );
    like( $log, qr/copies=2/, 'with the number of copies, which is the evidence' );
};

subtest 'and it stays quiet when nothing was multiplied' => sub {
    # The other half of the claim: a log line that fired on every page with a code
    # span would be noise, and noise is how a real one gets missed.
    page( 'quiet', <<'MD' );
---
title: Quiet
nocache: true
---

One span, rendered once: <code>just text</code>.
MD
    my $err  = "$docroot/stderr2.txt";
    my $proc = TestHelper::processor_path();
    local %ENV = %ENV;
    $ENV{DOCUMENT_ROOT}  = $docroot;
    $ENV{REDIRECT_URL}   = '/quiet';
    $ENV{REQUEST_METHOD} = 'GET';
    $ENV{QUERY_STRING}   = '';
    qx($^X \Q$proc\E 2>\Q$err\E);

    open my $fh, '<', $err or die "$err: $!";
    my $log = do { local $/; <$fh> };
    close $fh;

    unlike( $log, qr/multiplied a protected code block/,
        'an ordinary page with a code span logs nothing about this' );
};

# --- a fenced block in a loop is the same mechanism -------------------------
subtest 'a fenced block in a loop leaks the same way and is fixed the same way' => sub {
    page( 'fenced', <<'MD' );
---
title: Fenced
nocache: true
---

[% FOREACH n IN [ 1, 2 ] %]

    a fenced line [% n %]

[% END %]
MD
    my $out = run_processor( $docroot, '/fenced' );
    unlike( $out, qr/CODEBLOCK_/,
        'both protect passes share the restore, so both are covered' );
};

done_testing();
