#!/usr/bin/perl
# SM1335 (ruling 81, T-32, T-38 §1, T-39): A THEME'S COPIES FOLLOW ITS SOURCE.
#
# A theme has a source under lazysite/layouts/<L>/themes/<T>/ and a served copy
# per host: the docroot's /lazysite-assets/<L>/<T>/ and one under each content
# root. The copies were written at activation, apply, domain-add and creation
# only, so an edit to a theme a page pins (SM120), or one a secondary domain
# serves, never reached a visitor. A write to the source - through the choke
# point every manager, control API and MCP write passes - now re-mirrors that
# theme to every host's copy and drops the cached renders that use it; a write
# to a layout's own files drops the renders that use the layout.
#
# With the fix reverted, the copies keep the old bytes and the renders stay.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use JSON::PP   ();
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

sub slurp {
    open my $fh, '<', "$d/$_[0]" or return undef;
    local $/;
    return <$fh>;
}

# No primary layout, so nothing is the instance's active pair (SM749 would
# refuse it); the secondary domain serves site2/own from its own root, and
# gallery and its themes are no host's (rulings 109 and 120 hold a domain's
# active theme and layout read-only, as the primary's): pages pin them, and
# every host has their copies.
put( 'lazysite/lazysite.conf', <<'CONF' );
site_name: T
site_url: https://primary.example
alias_hosts: two.example
alias.two.example.content_root: sites/two
alias.two.example.layout: site2
alias.two.example.theme: own
CONF
put( 'lazysite/layouts/gallery/layout.tt', "[% content %]\n" );
put( 'lazysite/layouts/site2/layout.tt', "[% content %]\n" );
put( 'lazysite/layouts/site2/themes/own/theme.json', '{"name":"own"}' );
for my $t (qw(clarity other)) {
    put( "lazysite/layouts/gallery/themes/$t/theme.json",
        JSON::PP::encode_json( { name => $t, config => { colours => { primary => '#123456' } } } ) );
    put( "lazysite/layouts/gallery/themes/$t/assets/main.css", "/* $t v1 */\n" );
}

$Lazysite::Manager::Common::DOCROOT      = $d;
$Lazysite::Manager::Files::DOCROOT       = $d;
$Lazysite::Manager::Files::LOCK_DIR      = "$d/lazysite/locks";
$Lazysite::Manager::Themes::DOCROOT      = $d;
$Lazysite::Manager::Themes::LAZYSITE_DIR = "$d/lazysite";
$Lazysite::Manager::Domains::DOCROOT     = $d;
$Lazysite::Auth::Acl::DOCROOT            = $d;
{ no warnings 'once'; $Lazysite::Auth::Acl::token_auth = 0 }
# The operator at the manager: unconfined, so SM976 F1 asks nothing of it.
$Lazysite::Manager::Common::token_auth       = 0;
$Lazysite::Manager::Common::REQUEST_CONFINED = 0;
@Lazysite::Manager::Common::REQUEST_SCOPES   = ();

# The copies as an activation left them, then renders that link them.
Lazysite::Manager::Themes::_mirror_theme_assets( 'gallery', $_ ) for qw(clarity other);
sub renders {
    put( 'content/pinned.md',  "---\ntitle: P\nlayout: gallery\ntheme: clarity\n---\nP\n" );
    put( 'content/pinned.html', qq{<link href="/lazysite-assets/gallery/clarity/main.css?v=1">P\n} );
    put( 'content/other.md',   "---\ntitle: O\n---\nO\n" );
    put( 'content/other.html', qq{<link href="/lazysite-assets/gallery/other/main.css?v=1">O\n} );
    put( 'content/plain.md',   "---\ntitle: N\n---\nN\n" );
    put( 'content/plain.html', qq{<link href="/lazysite-assets/elsewhere/x/main.css">N\n} );
    put( 'sites/two/index.md', "---\ntitle: Two\ntheme: clarity\n---\nTwo\n" );
    put( 'sites/two/index.html', qq{<link href="/lazysite-assets/gallery/clarity/main.css">Two\n} );
    put( 'lazysite/cache/hosts/three.example/content/pinned.html',
        qq{<link href="/lazysite-assets/gallery/clarity/main.css">P\n} );
}
renders();

my $SRC = 'lazysite/layouts/gallery/themes/clarity';

subtest 'a source write reaches every host\'s copy of that theme' => sub {
    my $other_before = slurp('lazysite-assets/gallery/other/.fingerprint');
    my $r = Lazysite::Manager::Files::action_save( "$SRC/assets/main.css", 'op', "/* clarity v2 */\n" );
    ok( $r->{ok}, 'saved' ) or diag explain $r;
    is( slurp('lazysite-assets/gallery/clarity/main.css'), "/* clarity v2 */\n", 'the docroot\'s copy' );
    is( slurp('sites/two/lazysite-assets/gallery/clarity/main.css'), "/* clarity v2 */\n",
        'and the secondary domain\'s copy' );
    ok( -f "$d/sites/two/lazysite-assets/gallery/clarity/theme-tokens.css", 'with its tokens' );
    ok( -s "$d/sites/two/lazysite-assets/gallery/clarity/.fingerprint", 'and its version' );
    is( slurp('lazysite-assets/gallery/other/.fingerprint'), $other_before,
        'another theme\'s copy is left alone - one theme, not the site' );
    is_deeply( $r->{mirrors_refreshed}{themes}, ['gallery/clarity'], 'the reply names the theme it refreshed' );
    is( $r->{mirrors_refreshed}{copies}, 2, '...and how many copies' );
};

subtest 'the renders that use the theme go, and no others' => sub {
    ok( !-e "$d/content/pinned.html", 'the page that pins it' );
    ok( !-e "$d/sites/two/index.html", 'the secondary domain\'s page that pins it' );
    ok( !-e "$d/lazysite/cache/hosts/three.example/content/pinned.html", 'an alias host\'s copy of a render' );
    ok( -e "$d/content/other.html", 'a page on another theme stays' );
    ok( -e "$d/content/plain.html", 'and one on another layout' );
};

subtest 'a write to the layout\'s own files drops every render on it (T-38 §1)' => sub {
    renders();
    my $r = Lazysite::Manager::Files::action_save( 'lazysite/layouts/gallery/layout.tt', 'op', "<main>[% content %]</main>\n" );
    ok( $r->{ok}, 'saved' ) or diag explain $r;
    ok( !-e "$d/content/pinned.html", 'a page on one of its themes' );
    ok( !-e "$d/content/other.html", 'and on another' );
    ok( -e "$d/content/plain.html", 'a page on another layout stays' );
};

subtest 'a binary upload, a copy and a delete in the source follow too' => sub {
    my $r = Lazysite::Manager::Files::action_save_binary( "$SRC/assets/photo.jpg", 'op', "JPEG" );
    ok( $r->{ok}, 'uploaded' ) or diag explain $r;
    is( slurp('sites/two/lazysite-assets/gallery/clarity/photo.jpg'), 'JPEG', 'the upload reaches the secondary copy' );
    $r = Lazysite::Manager::Files::action_copy( "$SRC/assets/photo.jpg", "$SRC/assets/photo2.jpg", 'op' );
    ok( $r->{ok}, 'copied' ) or diag explain $r;
    ok( -f "$d/sites/two/lazysite-assets/gallery/clarity/photo2.jpg", 'the copy reaches it' );
    $r = Lazysite::Manager::Files::action_delete( "$SRC/assets/photo.jpg", 'op' );
    ok( $r->{ok}, 'deleted' ) or diag explain $r;
    ok( !-e "$d/lazysite-assets/gallery/clarity/photo.jpg", 'gone from the docroot\'s copy' );
    ok( !-e "$d/sites/two/lazysite-assets/gallery/clarity/photo.jpg", 'and from the secondary copy' );
};

subtest 'a source write makes a host\'s missing copy (ruling 111)' => sub {
    # A copy removed by hand, or a host whose copy was never written: the next
    # source write writes it, as every other host's.
    system( 'rm', '-rf', "$d/sites/two/lazysite-assets/gallery/clarity" );
    my $r = Lazysite::Manager::Files::action_save( "$SRC/assets/main.css", 'op', "/* clarity v3 */\n" );
    ok( $r->{ok}, 'saved' ) or diag explain $r;
    is( slurp('sites/two/lazysite-assets/gallery/clarity/main.css'), "/* clarity v3 */\n",
        'the secondary domain has its copy again' );
    ok( -s "$d/sites/two/lazysite-assets/gallery/clarity/.fingerprint", 'with its version' );
    is( $r->{mirrors_refreshed}{copies}, 2, 'and the reply counts it' );
};

subtest 'a theme whose source is gone takes its copies with it' => sub {
    system( 'rm', '-rf', "$d/lazysite/layouts/gallery/themes/other" );
    Lazysite::Manager::Themes::follow_source_write( $d, 'lazysite/layouts/gallery/themes/other' );
    ok( !-e "$d/lazysite-assets/gallery/other", 'the docroot\'s copy' );
    ok( !-e "$d/sites/two/lazysite-assets/gallery/other", 'and the secondary copy' );
};

subtest 'a link in the source is not copied into a served copy (SM1303)' => sub {
    symlink( "$d/lazysite/lazysite.conf", "$d/$SRC/assets/conf.css" ) or plan skip_all => 'no symlinks here';
    my $m = Lazysite::Manager::Themes::_mirror_theme_assets( 'gallery', 'clarity' );
    unlink "$d/$SRC/assets/conf.css";
    ok( !$m->{mirrored}, 'refused' ) or diag explain $m;
    like( $m->{reason} // '', qr/conf\.css/, 'naming the entry' );
    ok( !-e "$d/lazysite-assets/gallery/clarity/conf.css" && !-l "$d/lazysite-assets/gallery/clarity/conf.css",
        'and the link is in no copy' );
    ok( -f "$d/lazysite-assets/gallery/clarity/main.css", 'the copy before it stays served' );
};

subtest 'content and engine paths are not followed' => sub {
    is( Lazysite::Manager::Themes::follow_source_write( $d, 'content/pinned.md', 'lazysite/nav.conf' ), undef,
        'no theme or layout named, nothing done' );
};

done_testing;
