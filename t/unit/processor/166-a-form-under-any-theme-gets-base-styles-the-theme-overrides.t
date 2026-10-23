#!/usr/bin/perl
# SM1289: A FORM UNDER ANY THEME GETS BASE STYLES, AND THE THEME OVERRIDES THEM.
#
# Ruling 30 (edge observation O-4): under a theme with no form rules (lumen) a
# stepped form's fields and buttons were the browser's own. The engine now
# carries native-form base rules in lazysite-chrome.css, every one inside
# :where() so its specificity is zero, and links them on any page with a form,
# whether or not a layout renders it.
#
# Two halves, and each fails without the change:
#   - parsed from the stylesheet: the base rules are there, every selector of
#     every one of them is made only of :where() (so a theme rule of the lowest
#     specificity there is, one type selector, still beats each), and none sets
#     a colour a theme would have to undo;
#   - rendered: a page with a form under a layout links the file FIRST in its
#     head, ahead of the layout's own stylesheet (so even a theme's `*` rule
#     wins by order), once; a page under a layout without a form does not.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use File::Basename qw(dirname);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root setup_minimal_site setup_test_site run_processor site_tempdir);

my $ROOT = repo_root();
sub slurp { open my $f, '<:raw', $_[0] or die "$_[0]: $!"; local $/; my $t = <$f>; close $f; $t }
sub spit {
    my ( $p, $t ) = @_;
    make_path( dirname($p) );
    open my $f, '>:raw', $p or die "$p: $!";
    print {$f} $t;
    close $f;
}

# Selector lists split at their top-level commas (a :where() holds a list).
sub split_list {
    my ($list) = @_;
    my @out;
    my ( $cur, $depth ) = ( '', 0 );
    for my $ch ( split //, $list ) {
        $depth++ if $ch eq '(';
        $depth-- if $ch eq ')';
        if ( $ch eq ',' && !$depth ) { push @out, $cur; $cur = ''; next }
        $cur .= $ch;
    }
    push @out, $cur;
    return map { s/\s+/ /gr =~ s/^\s+|\s+$//gr } @out;
}

my $WHERE = qr/:where(\((?:[^()]++|(?-1))*\))/;

# The rules whose selector list opens with :where - the base rules.
my @base;
{
    my $css = slurp("$ROOT/starter/assets/lazysite-chrome.css");
    $css =~ s{/\*.*?\*/}{}gs;
    while ( $css =~ /([^{}]+)\{([^{}]*)\}/g ) {
        my ( $list, $decl ) = ( $1, $2 );
        my @sel = split_list($list);
        push @base, { sel => \@sel, decl => $decl } if grep { /\A:where\(/ } @sel;
    }
}
cmp_ok( scalar @base, '>=', 10, 'the native-form base rules are in the chrome (' . scalar(@base) . ' rules)' );

my @not_zero;
for my $r (@base) {
    for my $s ( @{ $r->{sel} } ) {
        ( my $rest = $s ) =~ s/$WHERE//g;
        push @not_zero, $s unless $s =~ /\A:where\(/ && $rest =~ /\A[\s>+~]*\z/;
    }
}
is_deeply( \@not_zero, [],
    'every selector of every base rule is only :where() - zero specificity, so a theme\'s '
        . 'lowest-specificity rule (a type selector) beats each one' )
    or diag("not inside :where(): @not_zero");

my @coloured;
for my $r (@base) {
    for my $d ( split /;/, $r->{decl} ) {
        my ( $p, $v ) = $d =~ /\A\s*([a-z-]+)\s*:\s*(.*?)\s*\z/s or next;
        push @coloured, "$p: $v"
            if $p =~ /\Abackground/
            || ( $p eq 'color' && $v !~ /\A(?:inherit|currentColor)\z/ )
            || $v =~ /#[0-9a-f]{3}|\b(?:rgba?|hsla?|var)\(/i;
    }
}
is_deeply( \@coloured, [], 'no base rule sets a colour beyond currentColor and inherit' )
    or diag("@coloured");

# What the ruling asked for is covered: spacing, full-width fields, buttons,
# the step bar and error text.
my $all = join ' ', map { @{ $_->{sel} } } @base;
for my $want ( [ 'the field spacing', qr/\.form-field\)/ ], [ 'the text inputs', qr/textarea, select/ ],
    [ 'the buttons', qr/\.lazysite-form button/ ], [ 'the step fieldsets', qr/\.lsf-step/ ],
    [ 'the error text', qr/\.form-status-error/ ], [ 'the sign-in forms', qr/\.login-form/ ] )
{
    like( $all, $want->[1], "a base rule covers $want->[0]" );
}

# --- rendered ---------------------------------------------------------------
my $LAYOUT = '<!DOCTYPE html><html><head><meta charset="utf-8"><title>[% page_title %]</title>'
    . '<link rel="stylesheet" href="/theme/main.css"></head><body>[% content %]</body></html>';

sub themed_site {
    my $d = site_tempdir();
    setup_test_site($d);
    spit( "$d/lazysite/layouts/test/layout.tt", $LAYOUT );
    spit( "$d/lazysite/layouts/test/themes/plain/theme.json", qq({"name":"plain","layouts":["test"]}\n) );
    open my $cf, '>>', "$d/lazysite/lazysite.conf" or die $!;
    print {$cf} "theme: plain\n";
    close $cf;
    return $d;
}

my %PAGE = (
    'a one-step form' => "---\ntitle: Ask\nform: ask\n---\n\n::: form\nname | Name | required\nsubmit | Send\n:::\n",
    'a stepped form'  => "---\ntitle: Apply\nform: apply\n---\n\n::: form\n"
        . "name | Name | required\n--- step: Contact ---\nemail | Email | required email\nsubmit | Send\n:::\n",
);
my $CHROME = qr{<link rel="stylesheet" href="/assets/lazysite-chrome\.css\?v=[^"]*">};

for my $what ( sort keys %PAGE ) {
    my $d = themed_site();
    spit( "$d/page.md", $PAGE{$what} );
    my $out = run_processor( $d, '/page' );
    my ( $hdr, $html ) = split /\r?\n\r?\n/, $out, 2;
    $html //= '';
    like( $html, qr/<form\b[^>]*class="lazysite-form"/, "$what under a layout: the form rendered" );
    my ($head) = $html =~ m{(<head\b.*?</head>)}is;
    $head //= '';
    like( $head, $CHROME, "$what under a layout: the base styles are linked in the head" );
    my @links = $head =~ /<link rel="stylesheet" href="([^"]+)"/g;
    like( $links[0] // '', qr{\A/assets/lazysite-chrome\.css}, "and first, ahead of the theme's stylesheet (@links)" );
    my $n = () = $html =~ /$CHROME/g;
    is( $n, 1, "$what under a layout: linked once, so no later copy puts the base rules after the theme" );
}

{
    my $d = themed_site();
    spit( "$d/plain.md", "---\ntitle: Plain\n---\n\nNo form here.\n" );
    my $out = run_processor( $d, '/plain' );
    unlike( $out, qr{/assets/lazysite-chrome\.css}, 'a page under a layout with no form does not link them' );
}

{
    my $d = themed_site();
    spit( "$d/lazysite/templates/system/login.md", slurp("$ROOT/starter/lazysite/templates/system/login.md") );
    my $out = run_processor( $d, '/login' );
    my ($head) = $out =~ m{(<head\b.*?</head>)}is;
    like( $head // '', $CHROME, 'the sign-in page under a layout links them too' );
}

{
    my $d = site_tempdir();
    setup_minimal_site($d);
    spit( "$d/page.md", $PAGE{'a one-step form'} );
    my $out = run_processor( $d, '/page' );
    like( $out, $CHROME, 'a form with no layout has them, through the fallback template' );
}

done_testing();
