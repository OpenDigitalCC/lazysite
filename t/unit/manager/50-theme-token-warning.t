#!/usr/bin/perl
# SM203: activating a theme that does not match the layout's OPTIONAL declared
# token vocabulary emits a non-fatal WARN and reports token_warnings in the
# result - activation still succeeds. A theme under a layout with no declared
# `tokens` block activates with no token warning.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP   qw(encode_json);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";

require Lazysite::Manager::Themes;
Lazysite::Manager::Themes->import(qw(action_theme_activate));
no warnings 'once';    # package vars set once from the test harness

# Build a docroot: layout 'declared' carries a tokens block; layout 'plain' does
# not. Each has themes.
my $d = tempdir( CLEANUP => 1 );
make_path(
    "$d/lazysite/layouts/declared/themes/full",
    "$d/lazysite/layouts/declared/themes/partial",
    "$d/lazysite/layouts/plain/themes/any",
    "$d/lazysite/manager/locks",
);

sub jwrite {
    my ( $rel, $data ) = @_;
    open my $fh, '>:utf8', "$d/lazysite/$rel" or die $!;
    print {$fh} ( ref $data ? encode_json($data) : $data );
    close $fh;
}

# layout 'declared' declares colours:[primary,text], fonts:[body].
jwrite( 'layouts/declared/layout.json', {
        name          => 'declared',
        version       => '1.0.0',
        default_theme => 'full',
        tokens        => { colours => [qw(primary text)], fonts => ['body'] },
} );
# 'full' supplies every declared token; 'partial' omits colours.text and adds an
# undeclared colours.accent.
jwrite( 'layouts/declared/themes/full/theme.json', {
        name   => 'full', version => '1.0.0', layouts => ['declared'],
        config => { colours => { primary => '#000', text => '#111' },
            fonts => { body => 'Inter' } },
} );
jwrite( 'layouts/declared/themes/partial/theme.json', {
        name   => 'partial', version => '1.0.0', layouts => ['declared'],
        config => { colours => { primary => '#000', accent => '#0AF' },
            fonts => { body => 'Inter' } },
} );

# layout 'plain' has NO tokens block.
jwrite( 'layouts/plain/layout.json',
    { name => 'plain', version => '1.0.0', default_theme => 'any' } );
jwrite( 'layouts/plain/themes/any/theme.json', {
        name   => 'any', version => '1.0.0', layouts => ['plain'],
        config => { colours => { whatever => '#333' } },
} );

$Lazysite::Manager::Themes::DOCROOT      = $d;
$Lazysite::Manager::Themes::LAZYSITE_DIR = "$d/lazysite";
$Lazysite::Manager::Themes::auth_user    = 'tester';
$Lazysite::Manager::Themes::action       = 'test';
$Lazysite::Manager::Files::LOCK_DIR      = "$d/lazysite/manager/locks";

sub set_active {
    my ( $layout, $theme ) = @_;
    open my $fh, '>', "$d/lazysite/lazysite.conf" or die $!;
    print {$fh} "site_name: t\nlayout: $layout\ntheme: $theme\n";
    close $fh;
}

# --- declared layout, theme that omits a declared token: WARN + token_warnings
set_active( 'declared', 'full' );
{
    my $r = action_theme_activate( 'partial', {} );
    ok( $r->{ok}, 'partial theme activates OK despite a token mismatch' );
    ok( $r->{token_warnings} && @{ $r->{token_warnings} },
        'token_warnings reported (non-fatal)' )
        or diag encode_json($r);
    ok( ( grep { /colours\.text/ } @{ $r->{token_warnings} } ),
        'the omitted declared token colours.text is flagged' );
    ok( ( grep { /colours\.accent/ } @{ $r->{token_warnings} } ),
        'the undeclared supplied token colours.accent is flagged' );
}

# --- declared layout, theme that supplies every declared token: no warnings ---
set_active( 'declared', 'partial' );
{
    my $r = action_theme_activate( 'full', {} );
    ok( $r->{ok}, 'full theme activates OK' );
    ok( !( $r->{token_warnings} && @{ $r->{token_warnings} } ),
        'a fully-covering theme reports no token warnings' )
        or diag encode_json($r);
}

# --- layout with NO declared block: activation, no token check at all ---------
set_active( 'plain', 'any' );
{
    # Re-activate the same theme (any -> any) - the check must be a clean no-op.
    my $r = action_theme_activate( 'any', {} );
    ok( $r->{ok}, 'theme under an undeclared-block layout activates OK' );
    ok( !exists $r->{token_warnings},
        'no declared block => no token_warnings key at all' );
}

done_testing();
