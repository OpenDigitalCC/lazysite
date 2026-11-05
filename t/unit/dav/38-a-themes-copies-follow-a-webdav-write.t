#!/usr/bin/perl
# SM1335 and SM1339 (ruling 81, T-32, T-38, T-39), over WebDAV.
#
# The 04/11 filing: a fix PUT to an inactive theme's source answered 204 and the
# pages that pin it kept the old stylesheet, because the served copy is written
# at activation only. The gallery filing (T-38 §1): every demo layout's
# layout.tt replaced over WebDAV, and each pinning page kept its old render. The
# 05/11 filing: an upload into the docroot's copy of a theme reached no other
# host, and was lost at the next activation.
#
# So, over this stack: a PUT, DELETE or MOVE in a theme's source re-mirrors it
# to every host's copy and drops the renders that use it; a PUT to a layout's
# files drops its renders; and a PUT, MKCOL, DELETE, MOVE or COPY into a served
# copy is refused, naming the source path.
#
# With the fix reverted the copies keep the old bytes, the renders stay, and the
# writes into a copy land.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper qw(setup_dav_site run_dav);
use Lazysite::Manager::Themes ();

my $s = setup_dav_site(
    caps => [qw(webdav manage_content manage_themes manage_layouts)],
    conf => <<'CONF' );
webdav_enabled: true
site_name: T
alias_hosts: two.example
alias.two.example.content_root: sites/two
alias.two.example.layout: plain
CONF
my $d = $s->{docroot};
# gallery/clarity is no host's: the pages that pin it (SM120) are what serve it,
# and the secondary domain has its copy all the same (SM734) - the 04/11 and
# 05/11 filings' case. A WebDAV account writes it (SM976 F1 asks only of a
# theme a site serves).

sub put {
    my ( $p, $c ) = @_;
    ( my $dir = "$d/$p" ) =~ s{/[^/]+\z}{};
    make_path($dir);
    open my $fh, '>', "$d/$p" or die "$p: $!";
    print {$fh} $c;
    close $fh;
    return;
}
sub slurp { open my $fh, '<', "$d/$_[0]" or return undef; local $/; <$fh> }
sub dav { run_dav( $d, $_[0], $_[1], HTTP_AUTHORIZATION => $s->{auth}, @_[ 2 .. $#_ ] ) }

put( 'lazysite/layouts/gallery/layout.tt', "[% content %]\n" );
put( 'lazysite/layouts/gallery/themes/clarity/theme.json', '{"name":"clarity","config":{"colours":{"primary":"#123"}}}' );
put( 'lazysite/layouts/gallery/themes/clarity/assets/main.css', "/* v1 */\n" );
{
    local $Lazysite::Manager::Themes::DOCROOT      = $d;
    local $Lazysite::Manager::Themes::LAZYSITE_DIR = "$d/lazysite";
    Lazysite::Manager::Themes::_mirror_theme_assets( 'gallery', 'clarity' );
}
sub renders {
    put( 'content/pinned.md',   "---\ntitle: P\nlayout: gallery\ntheme: clarity\n---\nP\n" );
    put( 'content/pinned.html', qq{<link href="/lazysite-assets/gallery/clarity/main.css?v=1">P\n} );
    put( 'content/plain.md',    "---\ntitle: N\n---\nN\n" );
    put( 'content/plain.html',  qq{<p>no theme</p>\n} );
}
renders();

my $SRC  = '/lazysite/layouts/gallery/themes/clarity/assets';
my $COPY = '/sites/two/lazysite-assets/gallery/clarity';

subtest 'a PUT to the source reaches every host\'s copy, with its tokens and version' => sub {
    my $fp = slurp('lazysite-assets/gallery/clarity/.fingerprint');
    my $r = dav( 'PUT', "$SRC/main.css", body => "/* v2 */\n" );
    is( $r->{code}, 204, 'written' ) or diag explain $r;
    is( slurp('lazysite-assets/gallery/clarity/main.css'), "/* v2 */\n", 'the docroot\'s copy' );
    is( slurp('sites/two/lazysite-assets/gallery/clarity/main.css'), "/* v2 */\n", 'the secondary copy' );
    ok( -f "$d/sites/two/lazysite-assets/gallery/clarity/theme-tokens.css", 'tokens in the copy' );
    isnt( slurp('lazysite-assets/gallery/clarity/.fingerprint'), $fp, 'a new version, so a new URL' );
    ok( !-e "$d/content/pinned.html", 'the pinning page\'s render is dropped' );
    ok( -e "$d/content/plain.html", 'a page on no theme of it stays' );
};

subtest 'a PUT to a pinned layout\'s template drops its pages (T-38 §1)' => sub {
    renders();
    my $r = dav( 'PUT', '/lazysite/layouts/gallery/layout.tt', body => "<main>[% content %]</main>\n" );
    is( $r->{code}, 204, 'written' ) or diag explain $r;
    ok( !-e "$d/content/pinned.html", 'the pinning page\'s render is dropped' );
};

subtest 'a DELETE and a MOVE in the source follow too' => sub {
    is( dav( 'PUT', "$SRC/photo.jpg", body => 'JPEG' )->{code}, 201, 'uploaded' );
    ok( -f "$d/sites/two/lazysite-assets/gallery/clarity/photo.jpg", 'in the secondary copy' );
    is( dav( 'MOVE', "$SRC/photo.jpg", HTTP_DESTINATION => "http://host/dav$SRC/hero.jpg" )->{code}, 201, 'moved' );
    ok( -f "$d/sites/two/lazysite-assets/gallery/clarity/hero.jpg", 'the new name is in the copy' );
    ok( !-e "$d/sites/two/lazysite-assets/gallery/clarity/photo.jpg", 'the old one is not' );
    is( dav( 'DELETE', "$SRC/hero.jpg" )->{code}, 204, 'deleted' );
    ok( !-e "$d/lazysite-assets/gallery/clarity/hero.jpg", 'and gone from the docroot\'s copy' );
};

subtest 'a write into a served copy is refused, naming the source' => sub {
    my %try = (
        'PUT, the secondary copy' => [ 'PUT', "$COPY/photo.jpg", body => 'JPEG' ],
        'PUT, the docroot copy'   => [ 'PUT', '/lazysite-assets/gallery/clarity/main.css', body => "x\n" ],
        'MKCOL'                   => [ 'MKCOL', "$COPY/img" ],
        'DELETE'                  => [ 'DELETE', "$COPY/main.css" ],
        'DELETE the whole copy'   => [ 'DELETE', $COPY ],
        'MOVE out'                => [ 'MOVE', "$COPY/main.css", HTTP_DESTINATION => 'http://host/dav/content/m.css' ],
        'COPY in'                 => [ 'COPY', '/content/plain.md', HTTP_DESTINATION => "http://host/dav$COPY/p.md" ],
    );
    for my $label ( sort keys %try ) {
        my $r = dav( @{ $try{$label} } );
        is( $r->{code}, 403, "$label: 403" ) or diag explain $r;
        like( $r->{headers}{'x-lazysite-deny-reason'} // '', qr{lazysite/layouts/gallery/themes/clarity/assets},
            "$label: the reason names the source" );
    }
    ok( !-e "$d/sites/two/lazysite-assets/gallery/clarity/photo.jpg", 'nothing landed' );
    ok( -f "$d/sites/two/lazysite-assets/gallery/clarity/main.css", 'nothing was removed' );
};

subtest 'reading a copy, and copying out of it, are not writes to it (controls)' => sub {
    is( dav( 'GET', "$COPY/main.css" )->{code}, 200, 'GET' );
    is( dav( 'COPY', "$COPY/main.css", HTTP_DESTINATION => 'http://host/dav/content/c.css' )->{code}, 201,
        'COPY out' );
    put( 'lazysite-assets/gallery/gone/x.css', "orphan\n" );
    is( dav( 'DELETE', '/lazysite-assets/gallery/gone' )->{code}, 204,
        'a copy of a theme no longer installed is cleanup' );
};

done_testing;
