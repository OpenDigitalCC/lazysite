#!/usr/bin/perl
# SM1280 (ruling 3, 2026-10-22; inbox 2026-10-22 P-8 to P-10, the OOM Lab's clock-in
# from the office network): a binding names an address profile (`address_profile`,
# ruling 58; for now an address profile's name, SM1134) and a yes/no
# parameter, and its operation receives ONLY whether the call came from inside that
# list - never the address. The server decides it from the request's address behind
# the trusted proxies (the endpoint's _ip, SM929), and nothing the page sends can set
# or override it. No address, an unknown list or an unreadable store is "not inside".
# The list is a reference the address-profile tools see, so it is not deleted unseen.
use strict;
use warnings;
use Test::More;
use JSON::PP qw(decode_json encode_json);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper qw(repo_root setup_minimal_site);
use OdooTest   qw(oom_or_skip shop_ready bind quiet odoo_site);

BEGIN { oom_or_skip() }
use Lazysite::Odoo               ();
use Lazysite::Odoo::Binding      ();
use Lazysite::Auth::AddressProfiles ();
use Lazysite::Auth::AddressRefs  ();

my $root = repo_root();
my ( $d, $fake ) = shop_ready();
setup_minimal_site($d);
odoo_site($d);
make_path("$d/lazysite/auth");
{
    no warnings 'once';
    local $Lazysite::Auth::AddressProfiles::AUTH_DIR = "$d/lazysite/auth";
    Lazysite::Auth::AddressProfiles::write_profiles( {
            office  => { entries => [ { cidr => '203.0.113.0/24', note => 'HQ' } ] },
            blocked => { entries => [ { cidr => '198.51.100.66', note => 'scanner' } ] } } );
}

sub save {
    my (%h) = @_;
    require Lazysite::Handlers;
    no warnings 'once';
    local $Lazysite::Handlers::DOCROOT = $d;
    my ( undef, $r ) = quiet( sub { Lazysite::Handlers::action_handler_save( { type => 'odoo', name => $h{id}, %h }, unconstrained => 1 ) } );
    return $r;
}
my %WHERE = ( operation => 'shop.where', modes => 'public', params => 'note=note' );

subtest 'a binding names the list and the parameter together, and the parameter has one source' => sub {
    like( save( id => 'w1', %WHERE, address_profile => 'office' )->{error} // '', qr/go together/, 'a list alone is refused' );
    like( save( id => 'w2', %WHERE, address_param => 'onsite' )->{error} // '', qr/go together/, 'a parameter alone is refused' );
    like( save( id => 'w3', %WHERE, address_profile => 'Office HQ', address_param => 'onsite' )->{error} // '',
        qr/not the name of an address profile/, 'a name that is not one is refused' );
    # old-address-name: begin (SM1343, the test sends the key that is refused)
    like( save( id => 'w8', %WHERE, address_list => 'office', address_param => 'onsite' )->{error} // '', qr/does not take: address_list\b/,
        'the old key address_list is no alias (ruling 56): it is refused by name' );
    # old-address-name: end
    like( save( id => 'w4', %WHERE, params => 'note=note, onsite=onsite', address_profile => 'office', address_param => 'onsite' )->{error} // '',
        qr/one source/, 'a parameter a request feeds cannot be the address parameter' );
    like( save( id => 'w5', %WHERE, fixed => 'onsite=1', address_profile => 'office', address_param => 'onsite' )->{error} // '',
        qr/one source/, 'nor one the operator fixes' );
    like( save( id => 'w6', %WHERE, params => '', address_profile => 'office', address_param => 'note' )->{error} // '',
        qr/bool/, 'the parameter is a yes/no one' );
    like( save( id => 'w7', %WHERE, modes => 'scheduled', address_profile => 'office', address_param => 'onsite' )->{error} // '',
        qr/scheduled run comes from no address/, 'a scheduled binding has no address to tell' );
    ok( save( id => 'where', %WHERE, address_profile => 'office', address_param => 'onsite' )->{ok}, 'a binding that names both is saved' );
    ok( save( id => 'where-deny', %WHERE, address_profile => 'blocked', address_param => 'onsite' )->{ok}, 'a deny list may be named: it is membership' );
    ok( save( id => 'where-gone', %WHERE, address_profile => 'nonesuch', address_param => 'onsite' )->{ok}, 'and one not (yet) in the store' );
};

sub run_at {
    my ( $id, $ip, $in ) = @_;
    my ( undef, $r ) = quiet( sub { my ($b) = Lazysite::Odoo::find_binding($id); Lazysite::Odoo::call( $b, $in // {}, mode => 'public', ip => $ip, strict => 1 ) } );
    return $r;
}
sub onsite { my ($r) = @_; return $r->{ok} ? $r->{report}{rows}[0]{onsite} : "refused: " . ( $r->{error} // '' ) }

subtest 'the operation is told inside or not, by the server' => sub {
    is( onsite( run_at( 'where', '203.0.113.9' ) ),  1, 'from inside the list: 1' );
    is( onsite( run_at( 'where', '198.51.100.3' ) ), 0, 'from outside: 0' );
    is( onsite( run_at( 'where', '' ) ),             0, 'from no address: 0' );
    is( onsite( run_at( 'where-deny', '198.51.100.66' ) ), 1, 'a deny list is asked for membership too' );
    is( onsite( run_at( 'where-gone', '203.0.113.9' ) ),   0, 'a list the store does not hold: 0' );
    my $r = run_at( 'where', '198.51.100.3', { onsite => 1 } );
    ok( !$r->{ok}, 'a request that sends the parameter itself is refused' ) or diag explain $r;
    like( $r->{error}, qr/does not take: onsite/, 'by name' );
    $r = run_at( 'where', '203.0.113.9', { note => 'hello' } );
    is( $r->{report}{rows}[0]{note}, 'hello', 'the binding\'s own fields still reach it' );
    unlike( encode_json($r), qr/203\.0\.113/, 'and the address is in nothing the operation was given or answered' );
};

subtest 'a store that will not read is not inside' => sub {
    my $p = "$d/lazysite/auth/address-profiles.json";
    rename $p, "$p.kept" or die $!;
    open my $fh, '>', $p or die $!;
    print {$fh} '{not json';
    close $fh;
    is( onsite( run_at( 'where', '203.0.113.9' ) ), 0, 'an undecodable store: 0' );
    rename "$p.kept", $p or die $!;
};

subtest 'the list is a reference the address-profile tools see' => sub {
    my @r = grep { $_->{where} eq 'binding' && $_->{ref} eq 'where' } @{ Lazysite::Auth::AddressRefs::rules($d)->{rules} };
    is_deeply( [ map { [ $_->{slot}, $_->{name} ] } @r ], [ [ 'match', 'office' ] ], 'named as a membership rule of the binding' );
};

# --- the endpoint: the address is _ip's, behind the trusted proxies -------------------
require "$root/lazysite-odoo.pl";
$Lazysite::Odoo::TRANSPORT = $fake;
sub get_at {
    my ( $query, %env ) = @_;
    my $out = '';
    {
        local %ENV = ( PATH => $ENV{PATH}, DOCUMENT_ROOT => $d, REQUEST_METHOD => 'GET', QUERY_STRING => $query,
            SCRIPT_NAME => '/cgi-bin/lazysite-odoo.pl', HTTP_HOST => 'localhost', CONTENT_LENGTH => 0, %env );
        local *STDOUT;
        open STDOUT, '>', \$out or die $!;
        quiet( sub { main::main() } );
    }
    my ( $head, $payload ) = split /\r\n\r\n/, $out, 2;
    my ($status) = $head =~ /Status:\s*(\d+)/;
    return ( $status // 0, ( eval { decode_json( $payload // '' ) } || {} ), $payload );
}

subtest 'at the page endpoint' => sub {
    my ( $s, $j, $raw ) = get_at( 'binding=where', REMOTE_ADDR => '203.0.113.20' );
    is( $s, 200, 'answered' ) or diag $raw;
    is( $j->{report}{rows}[0]{onsite}, 1, 'a visitor on the office network: inside' );
    unlike( $raw, qr/203\.0\.113\.20/, 'and the address is not in the answer' );
    ( undef, $j ) = get_at( 'binding=where', REMOTE_ADDR => '198.51.100.3' );
    is( $j->{report}{rows}[0]{onsite}, 0, 'a visitor elsewhere: not inside' );
    ( undef, $j ) = get_at( 'binding=where', REMOTE_ADDR => '10.0.0.2', HTTP_X_FORWARDED_FOR => '203.0.113.21' );
    is( $j->{report}{rows}[0]{onsite}, 1, 'behind a trusted front end, the visitor\'s address decides' );
    ( undef, $j ) = get_at( 'binding=where', REMOTE_ADDR => '198.51.100.3', HTTP_X_FORWARDED_FOR => '203.0.113.21' );
    is( $j->{report}{rows}[0]{onsite}, 0, 'a forwarded address from a peer that is not a trusted proxy is not believed' );
    ( $s, $j ) = get_at( 'binding=where&onsite=1', REMOTE_ADDR => '198.51.100.3' );
    is( $s, 400, 'a page that sends the parameter is refused' ) or diag explain $j;
};

done_testing;
