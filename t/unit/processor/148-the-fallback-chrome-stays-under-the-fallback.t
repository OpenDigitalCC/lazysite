#!/usr/bin/perl
# SM1250: THE FALLBACK PAGE CHROME APPLIES ONLY WHERE THE FALLBACK RENDERED.
#
# /assets/lazysite-chrome.css carries two things: the page chrome of the
# built-in fallback template, and the SM098 multi-step form rules. A page with a
# stepped form links it under ANY layout, and the page rules were bare element
# selectors (`body { ... max-width: 800px ... }`), so on a themed site every page
# with a stepped form took the system font, an 800px column and #333 text - the
# link comes after the theme's stylesheet and wins at equal specificity
# (reported from the OOM Lab, 2026-10-21).
#
# Two halves, and each fails without the change:
#   - every rule in the file is either under the fallback's body class or a
#     .lazysite-form rule, so nothing in it can reach a layout's page except
#     the form rules it was linked for;
#   - the fallback sets that class and a layout does not, for a stepped form
#     rendered both ways.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root setup_minimal_site setup_test_site run_processor site_tempdir);

my $CSS = repo_root() . '/starter/assets/lazysite-chrome.css';

# The selectors of every rule, comments removed. The file is flat CSS (no
# at-rules), which is asserted rather than assumed: an @media block would hide
# its rules from this split, so one arriving fails here and gets a look.
sub selectors_of {
    my ($css) = @_;
    $css =~ s{/\*.*?\*/}{}gs;
    unlike( $css, qr/@/, 'the chrome stylesheet has no at-rules, so every rule is read below' );
    my @sel;
    while ( $css =~ /([^{}]+)\{[^{}]*\}/g ) {
        my $list = $1;
        push @sel, map { s/^\s+|\s+$//gr } split /,/, $list;
    }
    return @sel;
}

{
    open my $fh, '<', $CSS or die "$CSS: $!";
    my $css = do { local $/; <$fh> };
    close $fh;
    my @sel = selectors_of($css);
    cmp_ok( scalar @sel, '>', 20, 'the stylesheet was read (' . scalar(@sel) . ' selectors)' );

    my @loose = grep { !/\A(?:body\.lazysite-fallback\b|\.lazysite-fallback\s|\.lazysite-form\b)/ } @sel;
    is_deeply( \@loose, [],
        'every rule is scoped to the fallback body or to a native form - '
            . 'none can restyle a layout\'s page' )
        or diag( "unscoped: @loose" );

    my @step = grep { /\A\.lazysite-form(?:\.lsf-js)?\[data-multistep\]/ } @sel;
    cmp_ok( scalar @step, '>=', 4, 'the multi-step rules are still there, unscoped by the fallback' );

    # SM1251: the native-form defaults the starter /contact.md carried inline
    # live here now, and only under the fallback, so a theme's form rules win.
    my %have = map { $_ => 1 } @sel;
    for my $want ( '.lazysite-fallback .lazysite-form',
        '.lazysite-fallback .lazysite-form .form-field',
        '.lazysite-fallback .lazysite-form .form-field.form-submit > button' )
    {
        ok( $have{$want}, "the fallback chrome styles a native form: $want" );
    }
}

my $page = "---\ntitle: Apply\nform: apply\n---\n\n::: form\n"
    . "name | Name | required\n--- step: Contact ---\nemail | Email | required email\n"
    . "submit | Send\n:::\n";

for my $case ( [ 'no layout', \&setup_minimal_site, 1 ], [ 'a layout', \&setup_test_site, 0 ] ) {
    my ( $what, $setup, $fallback ) = @$case;
    my $d = site_tempdir();
    $setup->($d);
    open my $fh, '>', "$d/apply.md" or die $!;
    print {$fh} $page;
    close $fh;
    my $out = run_processor( $d, '/apply' );

    like( $out, qr/data-multistep="1"/, "$what: the stepped form rendered" );
    like( $out, qr{<link rel="stylesheet" href="/assets/lazysite-chrome\.css},
        "$what: and links the chrome stylesheet for its step rules" );
    my ($body) = $out =~ /(<body\b[^>]*>)/i;
    $body //= '';
    if ($fallback) {
        like( $body, qr/\bclass="lazysite-fallback"/,
            "$what: the fallback's body carries the class its page rules are scoped to" );
    }
    else {
        unlike( $body, qr/lazysite-fallback/,
            "$what: a layout's body does not, so the page rules stay off it" );
    }
}

done_testing();
