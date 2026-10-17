#!/usr/bin/perl
# SM1113: a byte range on an engine-served static, through a REAL Apache.
#
# The field report, 2026-10-16: "A request with `Range: bytes=0-99` gets `200`
# and the whole file, with no `Accept-Ranges` header, on xisl.com (a 3.2 MB mp4
# and a png) and on edge (a favicon). Every response carries
# `x-lazysite-front: hestia-proxy/acl`."
#
# That header is the SM283 proxy template, which on a site with an ACL store
# sends every static to Apache; the Apache template's SM223 rule sends every
# existing file to lazysite-auth.pl; the wrapper execs the processor, whose
# _serve_content_static answers. t/unit/processor/130 drives the processor.
# This drives the chain the visitor's request takes from Apache on - the real
# wrapper and the real processor behind the template's own rewrite - because a
# CGI's 206 has to survive Apache's output filters to mean anything. The
# question this answers that the unit test cannot: does a range come back as a
# range, and UNCOMPRESSED, with mod_deflate switched on for everything.
use strict;
use warnings;
use Test::More;
use Time::HiRes qw(sleep);
use File::Path  qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root site_tempdir setup_test_site);

my $APACHE = -x '/usr/sbin/apache2' ? '/usr/sbin/apache2' : '';
plan skip_all => 'apache2 not installed' unless $APACHE;
my $MODS = '/usr/lib/apache2/modules';
plan skip_all => 'apache2 modules not found'
    unless -f "$MODS/mod_rewrite.so" && -f "$MODS/mod_deflate.so";
plan skip_all => 'no curl'
    unless system('sh -c "command -v curl >/dev/null 2>&1"') == 0;

my $root    = repo_root();
my $docroot = site_tempdir();
( my $site = $docroot ) =~ s{/[^/]+\z}{};
my $cgibin = "$site/cgi-bin";
make_path( $cgibin, "$site/logs", "$docroot/lazysite/auth",
    "$docroot/lazysite-assets/media" );
setup_test_site($docroot);

sub spit {
    my ( $p, $t ) = @_;
    open my $fh, '>', $p or die "$p: $!";
    binmode $fh;
    print {$fh} $t;
    close $fh;
    return;
}

# The site has an ACL store, which is the condition both template layers test.
spit( "$docroot/lazysite/auth/acls.json", "{}\n" );

my $BODY = join '', map { sprintf '%05d', $_ } 0 .. 1999;    # 10000 bytes
my $SIZE = length $BODY;
spit( "$docroot/lazysite-assets/media/clip.mp4", $BODY );
spit( "$docroot/lazysite-assets/media/notes.txt", $BODY );

# The REAL wrapper and processor, linked rather than copied: each resolves its
# own path to find its parts and lib, so they run from the tree under test.
# cgi-bin beside the docroot, as every installer lays it out, is where the
# wrapper looks for the processor when no LAZYSITE_PROCESSOR is threaded
# through - which the SM223 static rule does not do.
#
# The tree's scripts are not executable (the package sets the mode), so Apache
# runs a two-line shim that hands the request to the real wrapper unchanged;
# the wrapper execs the processor through perl, which needs no mode bit.
symlink "$root/lazysite-processor.pl", "$cgibin/lazysite-processor.pl"
    or die "symlink: $!";
spit( "$cgibin/lazysite-auth.pl",
    "#!$^X\nexec { \$^X } \$^X, '$root/lazysite-auth.pl' or die \"exec: \$!\\n\";\n" );
chmod 0755, "$cgibin/lazysite-auth.pl";

my $PORT = do {
    require IO::Socket::INET;
    my $s = IO::Socket::INET->new( LocalAddr => '127.0.0.1', Proto => 'tcp' )
        or die 'no port';
    my $p = $s->sockport;
    close $s;
    $p;
};

# The rewrite is the SM223 static rule from installers/hestia/lazysite-app.stpl,
# as written there. DEFLATE is on for EVERY response, which is harsher than any
# shipped configuration: if a range survives this, it survives a host's
# selective AddOutputFilterByType too.
spit( "$site/httpd.conf", <<"CONF" );
ServerRoot "$site"
ServerName 127.0.0.1
Listen 127.0.0.1:$PORT
PidFile "$site/httpd.pid"
ErrorLog "$site/logs/error.log"
LoadModule mpm_prefork_module $MODS/mod_mpm_prefork.so
LoadModule authz_core_module $MODS/mod_authz_core.so
LoadModule alias_module $MODS/mod_alias.so
LoadModule mime_module $MODS/mod_mime.so
LoadModule cgi_module $MODS/mod_cgi.so
LoadModule rewrite_module $MODS/mod_rewrite.so
LoadModule filter_module $MODS/mod_filter.so
LoadModule deflate_module $MODS/mod_deflate.so
TypesConfig /etc/mime.types
DocumentRoot "$docroot"
ScriptAlias /cgi-bin/ "$cgibin/"
<Directory "$cgibin">
    Options +ExecCGI +FollowSymLinks
    Require all granted
</Directory>
<Directory "$docroot">
    Options FollowSymLinks
    AllowOverride None
    Require all granted
</Directory>
SetOutputFilter DEFLATE
RewriteEngine On
RewriteCond %{DOCUMENT_ROOT}/lazysite/auth/acls.json -f [OR]
RewriteCond %{DOCUMENT_ROOT}-lazysite/auth/acls.json -f
RewriteCond %{REQUEST_URI} !^/cgi-bin/
RewriteCond %{DOCUMENT_ROOT}%{REQUEST_URI} -f
RewriteRule ^/(.*)\$ /cgi-bin/lazysite-auth.pl [PT,L]
CONF

sub apache { return system( $APACHE, '-f', "$site/httpd.conf", '-k', $_[0] ) == 0 }

# List-form exec, so no header reaches a shell (t/integration/49 says why).
sub fetch {
    my ( $path, @h ) = @_;
    my $head = grep { $_ eq '-I' } @h;
    my @cmd = ( 'curl', '-s', '-i', '--max-time', '10',
        ( map { $_ eq '-I' ? ('-I') : ( '-H', $_ ) } @h ),
        "http://127.0.0.1:$PORT$path" );
    my $pid = open my $ph, '-|';
    return {} unless defined $pid;
    if ( !$pid ) {
        open STDERR, '>', '/dev/null' or exit 127;
        exec @cmd;
        exit 127;
    }
    binmode $ph;
    my $out = do { local $/; <$ph> };
    close $ph;
    my ( $hd, $body ) = split /\r\n\r\n/, $out // '', 2;
    my ($status) = ( $hd // '' ) =~ m{\AHTTP/\S+ (\d{3})};
    my %h;
    for ( split /\r\n/, $hd // '' ) { $h{ lc $1 } = $2 if /^([^:]+):\s*(.*)$/ }
    return { status => $status // '', h => \%h, body => $body // '', head => $hd // '' };
}

unless ( apache('start') ) {
    my $err = '';
    if ( open my $fh, '<', "$site/logs/error.log" ) { local $/; $err = <$fh>; close $fh }
    plan skip_all => "apache2 would not start here: $err";
}
END { apache('stop') if $APACHE && -f "$site/httpd.pid" }

for ( 1 .. 50 ) {
    last if ( fetch('/lazysite-assets/media/clip.mp4')->{status} // '' ) =~ /\d/;
    sleep 0.1;
}

my $GZ = 'Accept-Encoding: gzip';

subtest 'the engine answers the asset, and DEFLATE is live' => sub {
    my $r = fetch( '/lazysite-assets/media/clip.mp4', $GZ );
    is( $r->{status}, '200', 'the clip is served' ) or do {
        diag( $r->{head} );
        if ( open my $fh, '<', "$site/logs/error.log" ) { local $/; diag(<$fh>); close $fh }
    };
    is( $r->{h}{'x-content-type-options'}, 'nosniff',
        'by the engine - Apache itself sets no security headers here' );
    is( $r->{h}{'content-type'}, 'video/mp4', 'SM1112: as video/mp4' );
    is( $r->{h}{'accept-ranges'}, 'bytes', 'and says ranges are accepted' );
    like( $r->{h}{'last-modified'} // '', qr/\A\w{3}, \d\d \w{3} \d{4} \d\d:\d\d:\d\d GMT\z/,
        'SM1120: and says when the file changed, through Apache' );

    # The control. Without it "no Content-Encoding on the range" below would
    # pass on a host where the deflate filter simply never ran.
    my $t = fetch( '/lazysite-assets/media/notes.txt', $GZ );
    is( $t->{h}{'content-encoding'}, 'gzip',
        'a whole text file IS compressed, so the filter is in the path' )
        or diag( $t->{head} );
};

subtest 'bytes=0-99 comes back as those bytes, uncompressed' => sub {
    for my $f (qw(clip.mp4 notes.txt)) {
        my $r = fetch( "/lazysite-assets/media/$f", $GZ, 'Range: bytes=0-99' );
        is( $r->{status}, '206', "$f: 206 Partial Content through Apache" )
            or diag( $r->{head} );
        is( $r->{h}{'content-range'}, "bytes 0-99/$SIZE", "$f: Content-Range" );
        ok( !defined $r->{h}{'content-encoding'},
            "$f: not compressed - a gzipped span is bytes of a representation "
                . 'nobody asked for' ) or diag( $r->{head} );
        is( $r->{body}, substr( $BODY, 0, 100 ), "$f: exactly the first 100 bytes" );
    }
};

subtest 'a suffix, and an open range, through Apache' => sub {
    my $r = fetch( '/lazysite-assets/media/clip.mp4', 'Range: bytes=-10' );
    is( $r->{h}{'content-range'}, "bytes 9990-9999/$SIZE", 'bytes=-10' );
    is( $r->{body}, substr( $BODY, -10 ), 'the last ten bytes' );

    $r = fetch( '/lazysite-assets/media/clip.mp4', 'Range: bytes=9000-' );
    is( $r->{h}{'content-range'}, "bytes 9000-9999/$SIZE", 'bytes=9000-' );
    is( $r->{body}, substr( $BODY, 9000 ), 'the last thousand bytes' );

    # The engine sends Content-Length on the 206 (t/unit/processor/130), and
    # Apache's CGI handler does not pass it on: measured here, a span it can
    # buffer whole (the ten bytes above) gets a Content-Length Apache computed,
    # and this thousand goes out chunked, with or without DEFLATE. A chunked
    # 206 is valid HTTP/1.1 - Content-Range carries the span - so this asserts
    # the bytes, not the header.
};

subtest 'an unsatisfiable range is 416 with the size' => sub {
    my $r = fetch( '/lazysite-assets/media/clip.mp4', "Range: bytes=$SIZE-" );
    is( $r->{status}, '416', '416 Range Not Satisfiable' ) or diag( $r->{head} );
    is( $r->{h}{'content-range'}, "bytes */$SIZE", 'Content-Range: bytes */size' );
};

subtest 'HEAD agrees with GET' => sub {
    my $g = fetch( '/lazysite-assets/media/clip.mp4', 'Range: bytes=0-99' );
    my $h = fetch( '/lazysite-assets/media/clip.mp4', '-I', 'Range: bytes=0-99' );
    is( $h->{status}, $g->{status}, 'the same status' );
    # content-length is left out for the reason given above: Apache, not the
    # engine, decides whether it is sent. The unit test compares it.
    for my $k (qw(content-type content-range accept-ranges etag)) {
        is( $h->{h}{$k}, $g->{h}{$k}, "the same $k" );
    }
};

done_testing();
