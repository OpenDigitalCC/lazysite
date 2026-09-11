#!/usr/bin/perl
# SM786: db-bound values reach the page escaped, and a template that was already
# careful is told so rather than left to render `&#39;`.
#
# The finding: front-matter scalars in the page stash were escaped and db: values
# were not - an asymmetry, not a policy - so whoever could write a row controlled
# markup, and therefore script, on any page displaying that table. The shipped
# examples taught the loop without a filter.
#
# Escaped at the SINK (`_escape_db_rows`, called by `resolve_db`) rather than by
# AUTO_FILTER on the render engines, because this is the one place every db value
# passes through and an engine filter would also re-escape what the engine itself
# puts in the stash.
#
# THE FAIL-SAFE IS THE PART WORTH TESTING HARDEST. A template already carrying
# `| html` now escapes an escaped value and shows `&#39;` where an apostrophe
# belongs: two correct things in sequence, producing a puzzling and
# harmless-looking defect. So the value is still escaped - failing safe - and the
# log says which table and column and what to do.
#
# Tested by calling the sink directly. A full render was tried for the sibling
# filing SM820 and produced a test that passed whether the fix was present or
# absent; calling the sub is the idiom the processor's other unit tests use and it
# cannot go vacuous the same way.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(load_processor setup_minimal_site site_tempdir);

my $docroot = site_tempdir();    # lint 118: not a bare tempdir
setup_minimal_site($docroot);
load_processor($docroot);

my $conf = "$docroot/lazysite/lazysite.conf";

# Run the sink and hand back both the rows and whatever it logged.
sub escape_rows {
    my ($rows) = @_;
    my $captured = '';
    my $out;
    {
        local *STDERR;
        open STDERR, '>', \$out or die "capture STDERR: $!";
        $rows = main::_escape_db_rows( $rows, 'catalogue', 'programmes' );
        close STDERR;
    }
    $captured = defined $out ? $out : '';
    return ( $rows, $captured );
}

# --- the finding itself -----------------------------------------------------
{
    my ( $rows, $log ) = escape_rows( [ { title => '<script>alert(1)</script>' } ] );
    is( $rows->[0]{title}, '&lt;script&gt;alert(1)&lt;/script&gt;',
        'a db value carrying markup is escaped at the sink' );
}

# The apostrophe matters: `_esc_html` covers it, so one default serves element
# text and either quoting style.
{
    my ( $rows ) = escape_rows( [ { title => q{it's "quoted" & <b>bold</b>} } ] );
    like( $rows->[0]{title}, qr/&#39;/,      'the apostrophe is escaped' );
    like( $rows->[0]{title}, qr/&quot;/,     'the double quote is escaped' );
    like( $rows->[0]{title}, qr/&amp;/,      'the ampersand is escaped' );
    unlike( $rows->[0]{title}, qr/<b>/,      'and the element is gone' );
}

# --- values that are not strings are left alone -----------------------------
{
    my ( $rows ) = escape_rows( [ { n => 42, missing => undef, list => [ 'a' ] } ] );
    is( $rows->[0]{n},    42,    'a number is untouched' );
    is( $rows->[0]{missing}, undef, 'an undef stays undef rather than becoming ""' );
    is( ref $rows->[0]{list}, 'ARRAY', 'a reference is not stringified' );
}

# --- THE FAIL-SAFE ----------------------------------------------------------
{
    my ( $rows, $log ) = escape_rows( [ { title => "Bob&#39;s programme" } ] );
    is( $rows->[0]{title}, 'Bob&amp;#39;s programme',
        'an already-escaped value is STILL escaped - it fails safe, not open' );
    like( $log, qr/already looks HTML-escaped/,
        'and the log says the value looked escaped already' );
    like( $log, qr/remove the \| html filter/,
        'and says what to do about it' );
    like( $log, qr/column/,
        'naming the column, so it can be found without staring at the page' );
}

# A value with no entities must NOT trip the fail-safe, or the warning becomes
# noise on every row of every table and stops being read.
{
    my ( undef, $log ) = escape_rows( [ { title => 'ordinary text, 1 & 2' } ] );
    unlike( $log, qr/already looks HTML-escaped/,
        'an ordinary value does not trip the warning' );
}

# --- the override it was born with is gone (N13-30) -------------------------
# db_render_raw shipped announced as deprecated and was removed in 0.13.13. A
# site that still carries the key gets the escaping anyway - a flag the engine
# no longer reads must not be able to turn a sink back into a hole.
{
    open my $fh, '>>', $conf or die $!;
    print $fh "db_render_raw: true\n";
    close $fh;

    my ($rows) = escape_rows( [ { title => '<b>raw</b>' } ] );
    is( $rows->[0]{title}, '&lt;b&gt;raw&lt;/b&gt;', 'db_render_raw no longer turns the escaping off' );
}

done_testing();
