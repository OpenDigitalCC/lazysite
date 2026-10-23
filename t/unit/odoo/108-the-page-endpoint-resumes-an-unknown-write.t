#!/usr/bin/perl
# SM1275 at the page endpoint (lazysite-odoo.pl): POST {run, resume: true} with the
# assume lists, under the token rule a confirm has - the visitor-bound token for a
# person signed in to Odoo, which a cross-site request cannot carry. A person whose
# session binding's apply left a change unknown resumes it from the page: "check
# again" is answered unknown-outcome (409) naming the change and saying they may
# assume; their word settles it. Another person signed in to Odoo cannot touch it.
# A visitor cannot resume a run of a public binding. A multipart request is never a
# resume.
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
use OdooSessionHTTP;
use Lazysite::Odoo          ();
use Lazysite::Odoo::Session ();
use Lazysite::Odoo::Visitor ();
use Odoo::Error;

my $root = repo_root();
my ( $d, $conn_fake ) = shop_ready( shop => { records => { 'x.basket' => [] } } );
setup_minimal_site($d);
odoo_site($d);
my $PW   = 'Quite-a-long-password-for-Jane-1';
my $mine = fake_shop( records => { 'x.basket' => [] } );
my $http = OdooSessionHTTP->new( fake => $mine, people => {
        'jane@example.com' => { password => $PW, uid => 7, name => 'Jane', login => 'jane@example.com' },
        'tom@example.com'  => { password => $PW, uid => 9, name => 'Tom',  login => 'tom@example.com' },
} );
$Lazysite::Odoo::Session::HTTP = $http;
{
    no warnings 'once';
    $Lazysite::Odoo::Visitor::DOCROOT = $d;
}
bind( $d, id => 'my-mix', operation => 'shop.mixed', credential => 'session', modes => 'authenticated',
    apply => 'immediate', params => 'title=title' );
bind( $d, id => 'open', operation => 'shop.mixed', modes => 'public', apply => 'immediate', params => 'title=title' );

require "$root/lazysite-odoo.pl";
$Lazysite::Odoo::TRANSPORT = $conn_fake;
my $SCRIPT = '/cgi-bin/lazysite-odoo.pl';

sub request {
    my ( $method, $query, $body, %env ) = @_;
    my $out  = '';
    my $json = defined $body ? ( ref $body ? encode_json($body) : $body ) : '';
    {
        local %ENV = ( PATH => $ENV{PATH}, DOCUMENT_ROOT => $d, REQUEST_METHOD => $method, QUERY_STRING => $query // '',
            REMOTE_ADDR => '198.51.100.3', SCRIPT_NAME => $SCRIPT, CONTENT_LENGTH => length $json,
            HTTP_HOST => 'localhost', CONTENT_TYPE => 'application/json', %env );
        local *STDOUT;
        open STDOUT, '>', \$out or die $!;
        local *STDIN;
        open STDIN, '<', \$json or die $!;
        quiet( sub { main::main() } );
    }
    my ( $head, $payload ) = split /\r\n\r\n/, $out, 2;
    my ($status) = $head =~ /Status:\s*(\d+)/;
    my @cookies = $head =~ /^Set-Cookie:\s*(.*?)\r?$/mg;
    return ( $status // 0, \@cookies, ( eval { decode_json( $payload // '' ) } || {} ), $out );
}
sub cv { my ( $c, $n ) = @_; for (@$c) { return $1 if /\A\Q$n\E=([^;]*)/ } return undef }

sub visitor {
    my ( undef, $vc, $tok ) = request( 'GET', 'csrf=1' );
    return ( 'lzs_odoo_visitor=' . cv( $vc, 'lzs_odoo_visitor' ), $tok->{visitor_token} );
}
sub signed_in {
    my ($login) = @_;
    my ( $VC, $VT ) = visitor();
    my ( $st, $ck ) = request( 'POST', '', { signin => 1, login => $login, password => $PW, visitor_token => $VT }, HTTP_COOKIE => $VC );
    die "no sign-in for $login ($st)\n" unless $st == 200;
    return ( "$VC; lzs_odoo_session=" . cv( $ck, 'lzs_odoo_session' ) . '; lzs_odoo_identity=' . cv( $ck, 'lzs_odoo_identity' ), $VT );
}
sub timeout { return Odoo::Error->new( kind => 'transport', sent => 1, write => 1, message => 'Timed out while waiting for socket to become ready for reading' ) }

my ( $JANE, $JT ) = signed_in('jane@example.com');
my ( $TOM,  $TT ) = signed_in('tom@example.com');

$mine->{fail}{'x.basket.create'} = timeout();
my ( $st, undef, $j ) = request( 'POST', '', { binding => 'my-mix', params => { title => 'R' }, visitor_token => $JT }, HTTP_COOKIE => $JANE );
is( $st, 207, 'the apply that left a change unknown answers 207, as SM1218 does' ) or diag explain $j;
my $RUN = $j->{run};
like( $RUN // '', qr/\A[0-9a-f]{32}\z/, 'and names the run' );
delete $mine->{fail}{'x.basket.create'};

subtest 'a resume carries the token a confirm carries' => sub {
    my ( $s, undef, $r ) = request( 'POST', '', { run => $RUN, resume => 1 }, HTTP_COOKIE => $JANE );
    is( $s, 403, 'no token: refused' );
    is( $r->{kind}, 'csrf', 'as csrf' );
    ( $s, undef, $r ) = request( 'POST', '', { run => $RUN, resume => 1, visitor_token => $TT }, HTTP_COOKIE => $JANE );
    is( $s, 403, 'another browser\'s token: refused' );
};

subtest 'its maker checks again, and is told who may say' => sub {
    my ( $s, undef, $r ) = request( 'POST', '', { run => $RUN, resume => 1, visitor_token => $JT }, HTTP_COOKIE => $JANE );
    is( $s,         409,               'check again: 409' ) or diag explain $r;
    is( $r->{kind}, 'unknown-outcome', 'unknown-outcome' );
    is_deeply( [ map { $_->{key} } @{ $r->{changes} } ], ['line:1'], 'naming the change' );
    is( $r->{may_assume}, 1, 'and that they may say' );
};

subtest 'another person signed in to Odoo cannot touch it' => sub {
    my ( $s, undef, $r ) = request( 'POST', '', { run => $RUN, resume => 1, visitor_token => $TT }, HTTP_COOKIE => $TOM );
    is( $s, 403, 'refused' ) or diag explain $r;
    is( $r->{kind}, 'not-yours', 'as not theirs' );
};

subtest 'its maker settles it' => sub {
    my $before = scalar @{ $mine->all_ids('x.basket') };
    my ( $s, undef, $r ) = request( 'POST', '', { run => $RUN, resume => 1, assume_not_done => ['line:1'], visitor_token => $JT },
        HTTP_COOKIE => $JANE );
    is( $s, 200, 'answered' ) or diag explain $r;
    ok( $r->{ok} && $r->{applied}, 'the rest applied' );
    is( scalar @{ $mine->all_ids('x.basket') }, $before + 1, 'the line is made, as the person' );
    ( $s, undef, $r ) = request( 'POST', '', { run => $RUN, resume => 1, visitor_token => $JT }, HTTP_COOKIE => $JANE );
    is( $r->{kind}, 'settled', 'and it is settled' );
};

subtest 'a visitor cannot resume a run of a public binding' => sub {
    my ( $VC, $VT ) = visitor();
    $conn_fake->{fail}{'x.basket.create'} = timeout();
    my ( $s, undef, $r ) = request( 'POST', '', { binding => 'open', params => {}, visitor_token => $VT }, HTTP_COOKIE => $VC );
    delete $conn_fake->{fail}{'x.basket.create'};
    is( $r->{unknown}, 1, 'unknown' ) or diag explain $r;
    ok( !exists $r->{run}, 'no run is offered' );
    ( $s, undef, $r ) = request( 'POST', '', { run => $r->{plan}, resume => 1, visitor_token => $VT }, HTTP_COOKIE => $VC );
    is( $s, 403, 'refused' ) or diag explain $r;
    is( $r->{kind}, 'mode', 'as mode' );
};

subtest 'a multipart request is never a resume' => sub {
    my $bnd  = 'XyZ';
    my $body = "--$bnd\r\nContent-Disposition: form-data; name=\"json\"\r\n\r\n"
        . encode_json( { run => $RUN, resume => 1, visitor_token => $JT } ) . "\r\n--$bnd--\r\n";
    my ( $s, undef, $r ) = request( 'POST', 'binding=my-mix', $body, HTTP_COOKIE => $JANE,
        CONTENT_TYPE => "multipart/form-data; boundary=$bnd" );
    is( $s, 400, 'refused' ) or diag explain $r;
};

done_testing;
