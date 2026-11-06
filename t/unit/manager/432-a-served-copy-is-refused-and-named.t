#!/usr/bin/perl
# SM1339 (ruling 81, T-39): A SERVED COPY OF A THEME IS WRITTEN BY NOBODY, AND A
# LISTING SAYS WHICH COPY A HOST SERVES.
#
# Every write the manager's Files page, the control API and MCP make passes the
# choke point's guard. A write into a host's /lazysite-assets/<L>/<T>/ - the
# docroot's or one under a content root - is refused there, for the operator
# too, naming the source path to write instead: the copy is replaced whole at
# the source's next write and reaches no other host (the 05/11 filing's six
# photographs). And action_list (list_files over MCP) marks a copy with its
# source and the hosts that serve it, each with whether the theme is active
# there - list_files showed three copies alike and nothing said which was live.
#
# Ruling 109: and the theme a secondary domain serves as its own is read-only
# as the primary's is - its SOURCE refused in place, naming the domain and the
# copy-edit-activate workflow, on the manager stack here and over WebDAV in
# t/unit/dav/38. A theme only pages pin stays writable. Ruling 120: and so is
# a domain's active layout, three.example's solo here; a layout only pages pin
# (gallery) stays writable. And theme-copy takes
# the theme by the path that refusal gives, lazysite/layouts/<L>/themes/<T>.
#
# With the fix reverted, every write lands and the listing carries no mark.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
BEGIN { $ENV{LAZYSITE_API_LOAD_ONLY} = 1 }
use TestHelper qw(site_tempdir);
use Lazysite::Manager::Files  ();
use Lazysite::Manager::Themes ();
use Lazysite::Auth::Acl       ();

my $d = site_tempdir();

sub put {
    my ( $p, $c ) = @_;
    ( my $dir = "$d/$p" ) =~ s{/[^/]+\z}{};
    make_path($dir);
    open my $fh, '>', "$d/$p" or die "$p: $!";
    print {$fh} $c;
    close $fh;
    return;
}

put( 'lazysite/lazysite.conf', <<'CONF' );
site_name: T
site_url: https://primary.example
layout: harmony
theme: base
alias_hosts: harmony2050.org, three.example
alias.harmony2050.org.content_root: sites/harmony2050.org
alias.harmony2050.org.theme: harmony-r3
alias.three.example.content_root: sites/three
alias.three.example.layout: solo
alias.three.example.theme: s1
CONF
put( 'lazysite/layouts/harmony/layout.tt', "[% content %]\n" );
for my $l (qw(solo gallery)) {
    put( "lazysite/layouts/$l/layout.tt", "[% content %]\n" );
    put( "lazysite/layouts/$l/themes/s1/theme.json", qq({"name":"s1"}) );
    put( "lazysite/layouts/$l/themes/spare/theme.json", qq({"name":"spare"}) );
}
for my $t (qw(base harmony-r3 spare)) {
    put( "lazysite/layouts/harmony/themes/$t/theme.json", qq({"name":"$t"}) );
    put( "lazysite/layouts/harmony/themes/$t/assets/main.css", "/* $t */\n" );
}
put( 'lazysite-assets/harmony/gone/main.css', "/* a copy of a theme no longer installed */\n" );
put( 'content/page.md', "---\ntitle: P\n---\nP\n" );

$Lazysite::Manager::Common::DOCROOT      = $d;
$Lazysite::Manager::Files::DOCROOT       = $d;
$Lazysite::Manager::Files::LOCK_DIR      = "$d/lazysite/locks";
$Lazysite::Manager::Themes::DOCROOT      = $d;
$Lazysite::Manager::Themes::LAZYSITE_DIR = "$d/lazysite";
$Lazysite::Manager::Domains::DOCROOT     = $d;
$Lazysite::Auth::Acl::DOCROOT            = $d;
{ no warnings 'once'; $Lazysite::Auth::Acl::token_auth = 0 }
# The operator at the manager - unconfined, and refused all the same.
$Lazysite::Manager::Common::token_auth       = 0;
$Lazysite::Manager::Common::REQUEST_CONFINED = 0;
@Lazysite::Manager::Common::REQUEST_SCOPES   = ();
Lazysite::Manager::Themes::_mirror_theme_assets( 'harmony', $_ ) for qw(base harmony-r3);

my $COPY  = 'lazysite-assets/harmony/harmony-r3';
my $SCOPY = "sites/harmony2050.org/$COPY";
my $SRC   = 'lazysite/layouts/harmony/themes/harmony-r3/assets';

sub refused {
    my ( $r, $label, $source ) = @_;
    ok( !$r->{ok}, "$label: refused" ) or diag explain $r;
    is( $r->{kind}, 'served-artifact-refused', "$label: by the served-artifact rule" );
    like( $r->{error} // '', qr/\Q$source\E/, "$label: naming the source to write" );
}

subtest 'every write verb into a served copy is refused, naming the source' => sub {
    my $F = 'Lazysite::Manager::Files';
    refused( $F->can('action_save')->( "$COPY/main.css", 'op', "x\n" ), 'save, docroot copy', "$SRC/main.css" );
    refused( $F->can('action_save')->( "$SCOPY/main.css", 'op', "x\n" ), 'save, secondary copy', "$SRC/main.css" );
    refused( $F->can('action_save_binary')->( "$SCOPY/photo.jpg", 'op', 'JPEG' ), 'upload', "$SRC/photo.jpg" );
    refused( $F->can('action_delete')->( "$COPY/main.css", 'op' ), 'delete', "$SRC/main.css" );
    refused( $F->can('action_mkdir')->( "$COPY/img", 'op' ), 'mkdir', "$SRC/img" );
    refused( $F->can('action_move')->( 'content/page.md', "$COPY/page.md", 'op' ), 'move into', "$SRC/page.md" );
    refused( $F->can('action_move')->( "$COPY/main.css", 'content/main.css', 'op' ), 'move out', "$SRC/main.css" );
    refused( $F->can('action_copy')->( 'content/page.md', "$SCOPY/page.md", 'op' ), 'copy into', "$SRC/page.md" );
    refused( $F->can('action_save')->( "$COPY/theme-tokens.css", 'op', "x\n" ), 'the tokens',
        'lazysite/layouts/harmony/themes/harmony-r3/theme.json' );
    refused( $F->can('action_save')->( 'lazysite-assets/harmony/stray.css', 'op', "x\n" ), 'a file in the layout\'s folder',
        'lazysite/layouts/harmony/themes/<theme>/assets/' );
    is( do { open my $f, '<', "$d/$SCOPY/main.css"; local $/; <$f> }, "/* harmony-r3 */\n", 'the copy is untouched' );
};

subtest 'what is not a served copy is not refused (controls)' => sub {
    my $F = 'Lazysite::Manager::Files';
    my $r = $F->can('action_copy')->( "$COPY/main.css", 'content/from-copy.css', 'op' );
    ok( $r->{ok}, 'copying OUT of a copy reads it, and is allowed' ) or diag explain $r;
    $r = $F->can('action_delete')->( 'lazysite-assets/harmony/gone/main.css', 'op' );
    ok( $r->{ok}, 'a copy of a theme no longer installed is cleanup, and is allowed' ) or diag explain $r;
    $r = $F->can('action_save')->( 'lazysite/layouts/harmony/themes/spare/assets/main.css', 'op', "/* v2 */\n" );
    ok( $r->{ok}, 'the source of a theme no host serves is written' ) or diag explain $r;
};

subtest 'a secondary domain\'s active theme is read-only, as the primary\'s (ruling 109)' => sub {
    my $F = 'Lazysite::Manager::Files';
    for my $try (
        [ 'save',   $F->can('action_save')->( "$SRC/main.css", 'op', "/* r3 v2 */\n" ) ],
        [ 'upload', $F->can('action_save_binary')->( "$SRC/photo.jpg", 'op', 'JPEG' ) ],
        [ 'delete', $F->can('action_delete')->( "$SRC/main.css", 'op' ) ],
        [ 'copy into', $F->can('action_copy')->( 'content/page.md', "$SRC/page.md", 'op' ) ] )
    {
        my ( $label, $r ) = @$try;
        ok( !$r->{ok}, "$label into harmony-r3's source: refused" ) or diag explain $r;
        is( $r->{kind}, 'active-artifact-refused', "$label: by the active-theme rule" );
        like( $r->{error} // '', qr/active theme of harmony2050\.org.*copy_theme.*with host/s,
            "$label: naming the domain and the workflow" );
    }
    is( do { open my $f, '<', "$d/$SRC/main.css"; local $/; <$f> }, "/* harmony-r3 */\n", 'the source is untouched' );
    my $r = $F->can('action_save')->( 'lazysite/layouts/harmony/themes/base/assets/main.css', 'op', "x\n" );
    is( $r->{kind}, 'active-artifact-refused', 'the primary\'s active theme is refused as before' );
    unlike( $r->{error} // '', qr/harmony2050/, '...in the primary\'s words' );
};

subtest 'a secondary domain\'s active layout is read-only, as the primary\'s (ruling 120)' => sub {
    my $F = 'Lazysite::Manager::Files';
    for my $try (
        [ 'layout.tt', $F->can('action_save')->( 'lazysite/layouts/solo/layout.tt', 'op', "<main>[% content %]</main>\n" ) ],
        [ 'a new file in it', $F->can('action_save')->( 'lazysite/layouts/solo/extra.tt', 'op', "x\n" ) ],
        [ 'a new folder in it', $F->can('action_mkdir')->( 'lazysite/layouts/solo/partials', 'op' ) ] )
    {
        my ( $label, $r ) = @$try;
        ok( !$r->{ok}, "$label: refused" ) or diag explain $r;
        is( $r->{kind}, 'active-artifact-refused', "$label: by the active-artifact rule" );
        like( $r->{error} // '', qr/active layout of three\.example.*activate it for that domain.*with host/s,
            "$label: naming the domain and the route" );
    }
    is( do { open my $f, '<', "$d/lazysite/layouts/solo/layout.tt"; local $/; <$f> }, "[% content %]\n",
        'the layout is untouched' );
    my $r = $F->can('action_save')->( 'lazysite/layouts/solo/themes/spare/theme.json', 'op', qq({"name":"spare","v":2}) );
    ok( $r->{ok}, 'a theme under it no host serves is still written' ) or diag explain $r;
    $r = $F->can('action_save')->( 'lazysite/layouts/gallery/layout.tt', 'op', "<main>[% content %]</main>\n" );
    ok( $r->{ok}, 'a layout only pages pin is written' ) or diag explain $r;
    $r = $F->can('action_save')->( 'lazysite/layouts/harmony/layout.tt', 'op', "x\n" );
    unlike( $r->{error} // '', qr/three\.example|harmony2050/, 'the primary\'s layout keeps the primary\'s words' );
};

subtest 'theme-copy takes the theme by its path too' => sub {
    my $T = 'Lazysite::Manager::Themes';
    my $r = $T->can('action_theme_copy')->( 'lazysite/layouts/harmony/themes/harmony-r3', 'harmony-r4' );
    ok( $r->{ok}, 'the path the refusal names is accepted' ) or diag explain $r;
    is( $r->{from}, 'harmony-r3', '...as the theme' );
    is( $r->{layout}, 'harmony', '...under the layout it names' );
    ok( -f "$d/lazysite/layouts/harmony/themes/harmony-r4/assets/main.css", 'the copy is made' );
    $r = $T->can('action_theme_copy')->( '/lazysite/layouts/harmony/themes/spare/', 'spare-2', { layout => 'harmony' } );
    ok( $r->{ok}, 'with slashes either side, and the same layout given' ) or diag explain $r;
    $r = $T->can('action_theme_copy')->( 'lazysite/layouts/harmony/themes/spare', 'spare-3', { layout => 'other' } );
    ok( !$r->{ok}, 'a path naming another layout than `layout` is refused' );
    like( $r->{error} // '', qr/'harmony'.*'other'/, '...naming both' );
    ok( !-e "$d/lazysite/layouts/harmony/themes/spare-3", '...and nothing is copied' );
    $r = $T->can('action_theme_copy')->( 'lazysite/layouts/harmony/themes/../x', 'bad' );
    ok( !$r->{ok}, 'a malformed name in the path is still refused' );
};

subtest 'a listing marks a copy, its source and the hosts that serve it' => sub {
    my $l = Lazysite::Manager::Files::action_list("/sites/harmony2050.org/lazysite-assets/harmony");
    ok( $l->{ok}, 'listed' ) or diag explain $l;
    my %e = map { $_->{name} => $_ } @{ $l->{entries} };
    my $sc = $e{'harmony-r3'}{served_copy};
    ok( $sc, 'the theme\'s copy is marked' ) or diag explain \%e;
    is( $sc->{level}, 'theme', '...as a theme\'s copy' );
    is( $sc->{source}, "$SRC/", '...naming its source' );
    is_deeply( [ map { $_->{host} } @{ $sc->{served_by} } ], ['harmony2050.org'], '...served to the secondary domain' );
    ok( $sc->{served_by}[0]{theme_active}, '...where it is the active theme' );
    ok( !$e{base}{served_copy}{served_by}[0]{theme_active}, 'base is served there and is not active' );
    is( $l->{served_copy}{level}, 'layout', 'the folder listed says what it is too' );

    $l = Lazysite::Manager::Files::action_list("/$COPY");
    my ($css) = grep { $_->{name} eq 'main.css' } @{ $l->{entries} };
    is( $css->{served_copy}{source}, "$SRC/main.css", 'a file in a copy names its own source file' );
    is_deeply( [ map { $_->{host} } @{ $css->{served_copy}{served_by} } ], ['primary.example'],
        'the docroot\'s copy is the primary\'s, named by its address' );
    ok( !$css->{served_copy}{served_by}[0]{theme_active}, '...and harmony-r3 is not active there' );

    $l = Lazysite::Manager::Files::action_list("/content");
    ok( !( grep { $_->{served_copy} } @{ $l->{entries} } ), 'ordinary content carries no mark' );
};

done_testing;
