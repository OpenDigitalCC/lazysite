#!/usr/bin/perl
# SEC (ADR 0006, mechanical enforcement): a raw:/api: page is served VERBATIM with
# no layout escaping, so a script-capable content_type declared by a content
# author (text/html, XHTML, SVG) is a stored-XSS vector - a manage_content-only
# partner could serve script that runs in every visitor's browser. Such a type is
# downgraded to text/plain (with the existing nosniff header, the browser cannot
# execute it). Safe artifact types (JSON/CSV/XML/plain/image) are unaffected.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(run_processor);

sub page {
    my ( $mode, $ct, $body ) = @_;
    my $d = tempdir( CLEANUP => 1 );
    make_path("$d/lazysite");
    open my $c, '>', "$d/lazysite/lazysite.conf" or die $!;
    print $c "site_name: T\n";
    close $c;
    open my $p, '>', "$d/art.md" or die $!;
    print $p "---\n$mode: true\ncontent_type: $ct\n---\n$body\n";
    close $p;
    my $out = run_processor( $d, '/art' );    # scalar context: whole response
    return $out;
}

sub ct_of { ( $_[0] =~ /^Content-type:\s*([^\r\n]+)/mi )[0] // '' }

# --- script-capable types are downgraded to text/plain -----------------------
for my $ct ( 'text/html', 'text/html; charset=utf-8',
    'application/xhtml+xml', 'image/svg+xml' )
{
    my $out = page( 'api', $ct, '<script>alert(1)</script>' );
    like( ct_of($out), qr{^text/plain}i,
        "api + $ct is downgraded to text/plain" );
    like( $out, qr/X-Content-Type-Options:\s*nosniff/i,
        "  ... and nosniff is set (no MIME sniff back to HTML)" );
}
{
    my $out = page( 'raw', 'text/html', '<script>alert(1)</script>' );
    like( ct_of($out), qr{^text/plain}i, 'raw + text/html is downgraded too' );
}

# --- safe artifact types are preserved ---------------------------------------
is( ct_of( page( 'api', 'application/json; charset=utf-8', '{"ok":1}' ) ),
    'application/json; charset=utf-8', 'api JSON keeps its content_type' );
is( ct_of( page( 'api', 'text/csv; charset=utf-8', 'a,b' ) ),
    'text/csv; charset=utf-8', 'api CSV keeps its content_type' );
like( ct_of( page( 'raw', 'application/xml', '<x/>' ) ),
    qr{^application/xml}, 'raw XML keeps its content_type' );

done_testing;
