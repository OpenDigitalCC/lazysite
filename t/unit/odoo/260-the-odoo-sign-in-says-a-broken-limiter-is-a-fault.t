#!/usr/bin/perl
# Ruling 212 (n795, the 0.16.9 restack): THE ODOO SIGN-IN SAYS A BROKEN RATE
# LIMITER IS A FAULT ON THE HOST, NOT "TOO MANY ATTEMPTS".
#
# Ruling 206 (n789, item 4) made the sign-in limiter refuse when it cannot count -
# no DB_File, a counter that will not open - and lazysite's own sign-in and the
# account door say so as cannot-tell (Lazysite::Auth::LoginRate::fault_refusal).
# The Odoo extension's sign-in still answered such a refusal as `rate`, "too many
# sign-in attempts - wait a few minutes and try again", which sends the person to
# wait for a fault that will not pass. Ruling 212 left its wording to the restack:
# it is now the limiter's own cannot-tell (503), and the password never reaches
# Odoo. A limiter that counts, over its cap, still answers `rate`.
use strict;
use warnings;
use Test::More;
use JSON::PP qw(decode_json encode_json);
use File::Path ();
use DB_File;
use Fcntl qw(O_RDWR O_CREAT);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper qw(repo_root setup_minimal_site);
use OdooTest   qw(oom_or_skip shop_ready quiet fake_shop odoo_site);

BEGIN { oom_or_skip() }
use OdooSessionHTTP;
use Lazysite::Odoo          ();
use Lazysite::Odoo::Session ();
use Lazysite::Odoo::Visitor ();

my $root = repo_root();
my ( $d, $conn_fake ) = shop_ready();
setup_minimal_site($d);
odoo_site($d);

my $FROM = '198.51.100.9';
my $PW   = 'Quite-a-long-password-for-Tove-1';

sub spit { my ( $p, $t ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh }

my $http = OdooSessionHTTP->new( fake => fake_shop(), people => {} );
$Lazysite::Odoo::Session::HTTP = $http;
$Lazysite::Odoo::TRANSPORT     = $conn_fake;
{
    no warnings 'once';
    $Lazysite::Odoo::Visitor::DOCROOT = $d;
}
File::Path::make_path( "$d/lazysite/auth", "$d/lazysite/logs" );
spit( "$d/lazysite/lazysite.conf",
    "site_name: T\nextensions:\n  - extensions/odoo.pl\n  - extensions/login-rate-limit.pl\ntrusted_proxies: 127.0.0.1\n" );

require "$root/lazysite-odoo.pl";
$Lazysite::Odoo::TRANSPORT = $conn_fake;

my $SCRIPT = '/cgi-bin/lazysite-odoo.pl';
sub request {
    my ( $method, $query, $body, %env ) = @_;
    my $out  = '';
    my $json = defined $body ? encode_json($body) : '';
    {
        local %ENV = (
            PATH => $ENV{PATH}, DOCUMENT_ROOT => $d, REQUEST_METHOD => $method, QUERY_STRING => $query // '',
            REMOTE_ADDR => '127.0.0.1', SCRIPT_NAME => $SCRIPT, CONTENT_LENGTH => length $json,
            HTTP_HOST => 'localhost', %env,
        );
        local *STDOUT;
        open STDOUT, '>', \$out or die $!;
        local *STDIN;
        open STDIN, '<', \$json or die $!;
        quiet( sub { main::main() } );
    }
    my ( $head, $payload ) = split /\r\n\r\n/, $out, 2;
    my ($status) = $head =~ /Status:\s*(\d+)/;
    my @cookies = $head =~ /^Set-Cookie:\s*(.*?)\r?$/mg;
    return ( $status // 0, \@cookies, ( eval { decode_json( $payload // '' ) } || {} ) );
}

sub cookie_value {
    my ( $cookies, $name ) = @_;
    for my $c (@$cookies) { return $1 if $c =~ /\A\Q$name\E=([^;]*)/ }
    return undef;
}

my ( undef, $vc, $tok ) = request( 'GET', 'csrf=1' );
my $VISITOR = 'lzs_odoo_visitor=' . cookie_value( $vc, 'lzs_odoo_visitor' );
my $VT      = $tok->{visitor_token};

my $n = 0;
sub signin {
    my $login = 'tove' . ++$n . '@example.com';
    $http->{people}{$login} = { password => $PW, uid => 100 + $n, name => "Tove $n", login => $login };
    return request( 'POST', '', { signin => 1, login => $login, password => $PW, visitor_token => $VT },
        HTTP_COOKIE => $VISITOR, HTTP_X_FORWARDED_FOR => $FROM );
}

my $DB = "$d/lazysite/auth/.login-rate.db";

subtest 'a limiter that counts: the sign-in goes through' => sub {
    my ( $st, $ck, $j ) = signin();
    is( $st, 200, 'signed in' ) or diag encode_json($j);
    ok( cookie_value( $ck, 'lzs_odoo_session' ), 'with a session' );
};

subtest 'a limiter that cannot count: cannot-tell, in the limiter\'s own words' => sub {
    unlink $DB;
    mkdir $DB or die "mkdir $DB: $!";    # a directory where the counter belongs: the tie fails
    my $posts = scalar @{ $http->posts };
    my ( $st, $ck, $j ) = signin();
    rmdir $DB;
    is( $st, 503, 'refused 503, not 429' ) or diag encode_json($j);
    is( $j->{kind}, 'cannot-tell', 'kind cannot-tell, not rate' );
    unlike( $j->{error} // '', qr/too many/i, 'never "too many sign-in attempts"' );
    like( $j->{error} // '', qr/rate limiter cannot count/, 'the limiter\'s own words' );
    like( $j->{error} // '', qr/fault on the host/, 'a fault on the host' );
    like( $j->{error} // '', qr/lazysite check --docroot <docroot>/, 'naming the check' );
    ok( !cookie_value( $ck, 'lzs_odoo_session' ), 'no session' );
    is( scalar @{ $http->posts }, $posts, 'Odoo was not asked: the password never left' );
};

subtest 'a limiter that counts, over its cap: still `rate`' => sub {
    my %db;
    tie %db, 'DB_File', $DB, O_CREAT | O_RDWR, 0o600 or die "tie: $!";
    $db{ "odoo-ip=$FROM:" . int( time() / 300 ) } = 99;
    untie %db;
    my ( $st, undef, $j ) = signin();
    is( $j->{kind}, 'rate', 'kind rate' ) or diag encode_json($j);
    like( $j->{error} // '', qr/too many sign-in attempts/, 'with the rate sentence' );
    unlink $DB;
};

done_testing();
