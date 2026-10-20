#!/usr/bin/perl
# SM1225 (ruled 2026-10-20, "OOM Lab questions": "build the download route (a binding
# option answering the report as a GET with its content type and a size cap; replaces
# base64-in-JSON; covers the quotation PDF and L-22)"). L-22: a payslip PDF came back
# as ~31 KB of base64 in one JSON answer.
#
# Held here, on OOM's fake Odoo and the endpoint driven as a CGI:
#   * a binding with `answer: download` is answered to a GET with the document's
#     BYTES, the Content-Type OOM gave, an attachment disposition and a file name,
#     Content-Length, Cache-Control private/no-store, nosniff;
#   * the same operation on a binding without the option still answers JSON;
#   * over `download_max_kb` is refused with a JSON too-large that names the size and the
#     cap, and not one byte of the document is in the answer;
#   * a binding's gate still decides: a gated binding refuses a signed-out GET, a session
#     binding answers "sign in", nothing reaches Odoo;
#   * a file name with quotes, newlines, slashes, semicolons and non-ASCII is made safe;
#     inline is honoured for a pdf and never for html; an odd type is octet-stream;
#   * a POST of a download binding, a write operation and a scheduled binding are refused;
#   * the rate cap counts a download as a call.
use strict;
use warnings;
use Test::More;
use JSON::PP qw(decode_json encode_json);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper qw(repo_root setup_minimal_site);
use OdooTest   qw(oom_or_skip shop_ready bind quiet odoo_site fake_shop);

BEGIN { oom_or_skip() }
use Lazysite::Odoo          ();
use Lazysite::Odoo::Visitor ();
use Lazysite::Handlers      ();
use Lazysite::Odoo::Session ();
use OdooSessionHTTP;

my $root = repo_root();
my ( $d, $fake ) = shop_ready();
setup_minimal_site($d);
odoo_site($d);
{
    no warnings 'once';
    $Lazysite::Odoo::Visitor::DOCROOT = $d;
}

sub save {
    my (%h) = @_;
    no warnings 'once';
    local $Lazysite::Handlers::DOCROOT = $d;
    return Lazysite::Handlers::action_handler_save( { type => 'odoo', name => $h{id}, %h }, unconstrained => 1 );
}

subtest 'saving: the option is known, checked and only for a read' => sub {
    my %b = ( operation => 'shop.document', modes => 'public' );
    my $r = save( id => 'okd', %b, answer => 'download', download_max_kb => 50, download_disposition => 'inline' );
    ok( $r->{ok}, 'answer: download with a cap and a disposition is accepted' ) or diag explain $r;
    $r = save( id => 'badans', %b, answer => 'file' );
    ok( !$r->{ok}, 'an unknown answer is refused' );
    like( $r->{error} // '', qr/answer must be json or download/, 'saying what it takes' );
    $r = save( id => 'badcap', %b, answer => 'download', download_max_kb => 'lots' );
    ok( !$r->{ok}, 'a cap that is not a number is refused' );
    $r = save( id => 'bigcap', %b, answer => 'download', download_max_kb => 999999 );
    ok( !$r->{ok}, 'a cap above the ceiling is refused' );
    like( $r->{error} // '', qr/ceiling/, 'naming the ceiling' );
    $r = save( id => 'baddisp', %b, answer => 'download', download_disposition => 'frame' );
    ok( !$r->{ok}, 'a disposition other than attachment or inline is refused' );
    $r = save( id => 'strayd', %b, download_max_kb => 5 );
    ok( !$r->{ok}, 'a download setting on a binding that answers JSON is refused, not ignored' );
    $r = save( id => 'sched', %b, modes => 'scheduled', answer => 'download' );
    ok( !$r->{ok}, 'a scheduled download is refused: nobody to give it to' );
    $r = save( id => 'wr', operation => 'shop.add', modes => 'public', apply => 'immediate', answer => 'download' );
    ok( !$r->{ok}, 'an operation that writes cannot be a download' ) or diag explain $r;
    like( $r->{error} // '', qr/writes/, 'saying why' );
    $r = save( id => 'dflt', %b );
    ok( $r->{ok}, 'a binding without the option is as it was' );
};

bind( $d, id => 'quote', operation => 'shop.document', modes => 'public', params => 'name=name,mimetype=mimetype,size=size,rows=rows',
    answer => 'download', download_max_kb => 4 );
bind( $d, id => 'quote_json', operation => 'shop.document', modes => 'public', params => 'name=name,size=size' );
bind( $d, id => 'quote_show', operation => 'shop.document', modes => 'public', params => 'name=name,mimetype=mimetype',
    answer => 'download', download_disposition => 'inline' );
bind( $d, id => 'quote_staff', operation => 'shop.document', modes => 'authenticated', callers => 'staff',
    answer => 'download' );
bind( $d, id => 'quote_mine', operation => 'shop.document', credential => 'session', modes => 'authenticated',
    answer => 'download' );
bind( $d, id => 'quote_slow', operation => 'shop.document', modes => 'public', answer => 'download',
    rate_per_hour => 2, rate_per_visitor_hour => 2 );

require "$root/lazysite-odoo.pl";
$Lazysite::Odoo::TRANSPORT = $fake;
my $PW   = 'Quite-a-long-password-for-Jane-1';
my $http = OdooSessionHTTP->new( fake => fake_shop(), people => {
        'jane@example.com' => { password => $PW, uid => 7, name => 'Jane', login => 'jane@example.com' },
} );
$Lazysite::Odoo::Session::HTTP = $http;

# One request. ( status, header-text, body bytes )
sub get {
    my ( $query, %env ) = @_;
    my $out = '';
    {
        local %ENV = ( PATH => $ENV{PATH}, DOCUMENT_ROOT => $d, REQUEST_METHOD => 'GET', QUERY_STRING => $query,
            REMOTE_ADDR => '198.51.100.3', SCRIPT_NAME => '/cgi-bin/lazysite-odoo.pl', HTTP_HOST => 'localhost', %env );
        local *STDOUT;
        open STDOUT, '>', \$out or die $!;
        quiet( sub { main::main() } );
    }
    my ( $head, $body ) = split /\r\n\r\n/, $out, 2;
    my ($status) = $head =~ /Status:\s*(\d+)/;
    return ( $status // 0, $head, $body // '' );
}
sub hdr { my ( $h, $n ) = @_; return $h =~ /^\Q$n\E:\s*(.*?)\r?$/mi ? $1 : undef }
sub post {
    my ($body) = @_;
    my $in  = encode_json($body);
    my $out = '';
    {
        local %ENV = ( PATH => $ENV{PATH}, DOCUMENT_ROOT => $d, REQUEST_METHOD => 'POST', QUERY_STRING => '',
            REMOTE_ADDR => '198.51.100.3', SCRIPT_NAME => '/cgi-bin/lazysite-odoo.pl', HTTP_HOST => 'localhost',
            CONTENT_LENGTH => length $in, CONTENT_TYPE => 'application/json', HTTP_COOKIE => $::VC );
        local *STDOUT;
        open STDOUT, '>', \$out or die $!;
        local *STDIN;
        open STDIN, '<', \$in or die $!;
        quiet( sub { main::main() } );
    }
    my ( $head, $payload ) = split /\r\n\r\n/, $out, 2;
    my ($status) = $head =~ /Status:\s*(\d+)/;
    return ( $status, eval { decode_json($payload) } || {} );
}

my $PDF = "%PDF-1.4\n" . ( 'p' x 83 ) . "\x00\xFF\x80\r\n\r\n\x1a";

subtest 'a download binding answers a GET with the document and its headers' => sub {
    my ( $st, $h, $body ) = get('binding=quote&size=100');
    is( $st, 200, 'answered' ) or diag "$h\n$body";
    is( $body, $PDF, 'the body is the document, byte for byte' );
    is( hdr( $h, 'Content-Type' ), 'application/pdf', 'the type OOM gave' );
    is( hdr( $h, 'Content-Length' ), length $PDF, 'Content-Length is its length' );
    is( hdr( $h, 'Content-Disposition' ), 'attachment; filename="quotation.pdf"', 'an attachment with the name OOM gave' );
    is( hdr( $h, 'Cache-Control' ), 'private, no-store', 'private, no-store: it is one person\'s' );
    is( hdr( $h, 'X-Content-Type-Options' ), 'nosniff', 'nosniff' );
    like( hdr( $h, 'Content-Security-Policy' ) // '', qr/^sandbox\b/, 'sandboxed' );
    unlike( $h, qr/application\/json/, 'not a JSON answer' );
    unlike( $body, qr/content_base64/, 'and no base64' );
};

subtest 'a binding without the option still answers the report as JSON' => sub {
    my ( $st, $h, $body ) = get('binding=quote_json&size=100');
    is( $st, 200, 'answered' );
    like( hdr( $h, 'Content-Type' ) // '', qr/application\/json/, 'JSON' );
    my $j = decode_json($body);
    ok( $j->{ok}, 'ok' );
    like( $j->{report}{rows}[0]{content_base64} // '', qr/\S/, 'the document in base64, as before' );
};

subtest 'over the cap is refused, whole, with a clear JSON error' => sub {
    my ( $st, $h, $body ) = get('binding=quote&size=' . ( 4 * 1024 + 1 ));
    is( $st, 413, 'status 413' ) or diag "$h\n$body";
    like( hdr( $h, 'Content-Type' ) // '', qr/application\/json/, 'JSON' );
    my $j = decode_json($body);
    is( $j->{kind}, 'too-large', 'too-large' );
    like( $j->{error}, qr/4097 bytes.*4 KB.*download_max_kb/s, 'naming the size and the cap' );
    unlike( $body, qr/%PDF|content_base64/, 'not a byte of the document' );
    ( $st, $h, $body ) = get('binding=quote&size=' . 4 * 1024);
    is( $st, 200, 'exactly at the cap passes' );
    is( length $body, 4 * 1024, 'whole' );
};

subtest 'more or fewer than one document is not a download' => sub {
    my ( $st, undef, $body ) = get('binding=quote&size=100&rows=2');
    is( $st, 400, 'two documents: refused' );
    is( decode_json($body)->{kind}, 'invalid', 'invalid' );
    ( $st, undef, $body ) = get('binding=quote&size=100&rows=0');
    is( $st, 400, 'none: refused' );
};

subtest 'a file name is made safe' => sub {
    my %want = (
        "evil\"; x=y.pdf"                      => 'evil_ x_y.pdf',
        "line1\r\nSet-Cookie: a=b\r\n.pdf"     => 'Set-Cookie_ a_b_.pdf',
        '../../etc/passwd'                     => 'passwd',
        '..\\..\\win\\system.pdf'              => 'system.pdf',
        "caf\x{e9} \x{4e2d}.pdf"               => 'caf_ _.pdf',
        '...'                                  => 'report.pdf',
        ''                                     => 'report.pdf',
        ( 'a' x 300 ) . '.pdf'                 => 'a' x 100,
    );
    for my $name ( sort keys %want ) {
        my $enc = join '', map { sprintf '%%%02X', $_ } unpack 'C*', do { my $n = $name; utf8::encode($n) if utf8::is_utf8($n); $n };
        my ( $st, $h ) = get("binding=quote&size=100&name=$enc");
        my ($cd) = $h =~ /^Content-Disposition:\s*(.*?)\r?$/mi;
        is( $st, 200, 'answered' );
        unlike( $h, qr/^Set-Cookie/mi, 'no header was injected' ) if $name =~ /Set-Cookie/;
        my $count = () = $h =~ /^Content-Disposition:/mgi;
        is( $count, 1, 'one Content-Disposition' );
        unlike( $cd // '', qr/[\r\n]/, 'no line break in it' );
        like( $cd // '', qr/\Aattachment; filename="[A-Za-z0-9._ -]*"\z/, 'only safe characters inside the quotes' ) or diag $cd;
        my ($f) = $cd =~ /filename="(.*)"/;
        unlike( $f // '', qr{[/\\]}, 'no path' );
        unlike( $f // '', qr/^\./, 'not hidden' );
        ok( length($f) <= 100, 'at most 100' );
    }
    my ( undef, $h ) = get('binding=quote&size=100&name=..%2F..%2Fetc%2Fpasswd');
    like( $h, qr/filename="passwd"/, 'a path is cut to its last part' );
    ( undef, $h ) = get('binding=quote&size=100&name=%2E%2E%2E');
    like( $h, qr/filename="report\.pdf"/, 'a name with nothing left is report.pdf' );
};

subtest 'inline is for a pdf, an image or text, never for html; an odd type is octet-stream' => sub {
    my ( $st, $h ) = get('binding=quote_show&name=q.pdf');
    like( hdr( $h, 'Content-Disposition' ), qr/^inline; filename="q\.pdf"/, 'a pdf is shown where the binding says inline' );
    ( $st, $h ) = get('binding=quote_show&name=q.html&mimetype=text%2Fhtml');
    like( hdr( $h, 'Content-Disposition' ), qr/^attachment;/, 'html is saved, whatever the binding says' );
    is( hdr( $h, 'Content-Type' ), 'text/html', 'its type' );
    ( $st, $h ) = get('binding=quote&size=100&mimetype=text%2Fhtml%0D%0AX-Evil%3A%201');
    is( hdr( $h, 'Content-Type' ), 'application/octet-stream', 'a type that is not a type/subtype name is octet-stream' );
    unlike( $h, qr/X-Evil/, 'nothing injected' );
    ( $st, $h ) = get('binding=quote&size=100&mimetype=IMAGE%2FPNG&name=a');
    is( hdr( $h, 'Content-Type' ), 'image/png', 'a type is lower-cased' );
    like( hdr( $h, 'Content-Disposition' ), qr/attachment; filename="a"/, 'attachment by default' );
};

subtest 'the binding\'s gate still decides' => sub {
    my $c0 = scalar @{ $fake->calls };
    my ( $st, $h, $body ) = get('binding=quote_staff');
    is( $st, 403, 'a gated binding refuses a signed-out GET' );
    is( decode_json($body)->{kind}, 'mode', 'by its mode' );
    like( hdr( $h, 'Content-Type' ), qr/json/, 'as JSON' );
    unlike( $body, qr/%PDF/, 'no document' );
    ( $st, $h, $body ) = get('binding=quote_mine');
    is( $st, 401, 'a session binding with no Odoo session: sign in' );
    is( decode_json($body)->{kind}, 'signin-required', 'signin-required' );
    is( scalar @{ $fake->calls }, $c0, 'and nothing reached Odoo' );
    ( $st, $h, $body ) = get('binding=nothere');
    is( $st, 404, 'an unknown binding' );
};

subtest 'a person signed in to Odoo is given their document through a session binding' => sub {
    my ( undef, $vh, $vb ) = get('csrf=1');
    my ($vc) = $vh =~ /^Set-Cookie:\s*(lzs_odoo_visitor=[^;]*)/mi;
    my $vt = decode_json($vb)->{visitor_token};
    my $in = encode_json( { signin => 1, login => 'jane@example.com', password => $PW, visitor_token => $vt } );
    my $out = '';
    {
        local %ENV = ( PATH => $ENV{PATH}, DOCUMENT_ROOT => $d, REQUEST_METHOD => 'POST', QUERY_STRING => '',
            REMOTE_ADDR => '198.51.100.3', SCRIPT_NAME => '/cgi-bin/lazysite-odoo.pl', HTTP_HOST => 'localhost',
            CONTENT_LENGTH => length $in, CONTENT_TYPE => 'application/json', HTTP_COOKIE => $vc );
        local *STDOUT;
        open STDOUT, '>', \$out or die $!;
        local *STDIN;
        open STDIN, '<', \$in or die $!;
        quiet( sub { main::main() } );
    }
    my ($sess) = $out =~ /^Set-Cookie:\s*(lzs_odoo_session=[^;]*)/mi;
    ok( $sess, 'signed in' ) or diag $out;
    my ( $st, $h, $body ) = get( 'binding=quote_mine', HTTP_COOKIE => "$vc; $sess" );
    is( $st, 200, 'answered' ) or diag "$h\n$body";
    is( $body, $PDF, 'the document' );
    is( hdr( $h, 'Cache-Control' ), 'private, no-store', 'private, no-store' );
};

subtest 'a POST of a download binding is refused, and the rate cap counts the GETs' => sub {
    my ( undef, $vh, $vb ) = get('csrf=1');
    my ($vc) = $vh =~ /^Set-Cookie:\s*(lzs_odoo_visitor=[^;]*)/mi;
    $::VC = $vc;
    my $vt = decode_json($vb)->{visitor_token};
    my ( $st, $j ) = post( { binding => 'quote', visitor_token => $vt, params => {} } );
    is( $st, 405, 'POST: 405' );
    is( $j->{kind}, 'method', 'method' );
    like( $j->{error}, qr/GET it/, 'saying to GET it' );

    my @st = map { ( get( 'binding=quote_slow', HTTP_COOKIE => $vc ) )[0] } 1 .. 3;
    is_deeply( \@st, [ 200, 200, 429 ], 'two inside the cap, the third refused rate' );
};

done_testing();
