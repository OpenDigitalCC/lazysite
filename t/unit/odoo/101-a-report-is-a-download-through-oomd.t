#!/usr/bin/perl
# SM1225: THE DOWNLOAD IS THE SAME WHEN THE REAL oomd ANSWERS THE CALL.
#
# The document reaches the endpoint as the report of the call; whether the call ran in
# this process or in oomd, the report is the same, and so is the response made of it.
# The tell for the path is the call record's `via` (SM1164), and a cap that the endpoint
# applies to what the daemon returned. The REAL oomd runs (t/vendor/oom/bin/oomd), against
# OOM's fake Odoo, with this repository's test pack on its path.
use strict;
use warnings;
use Test::More;
use JSON::PP qw(decode_json);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper qw(repo_root setup_minimal_site);
use OdooTest   qw(oom_or_skip bind quiet fake_shop);

BEGIN { oom_or_skip() }
use OdooDaemonTest qw(oomd_site oomd_env oomd_start oomd_stop oomd_up wait_until);
use Lazysite::Odoo ();
use Lazysite::Daemon::Service::Oomd ();

my $root  = repo_root();
my $state = oomd_env();
$ENV{PERL5LIB} .= ':' . $root . '/t/lib';    # the daemon loads this test pack too
my $d = oomd_site( odoo_packs => 'LazysiteTest::OdooOps' );
$Lazysite::Odoo::DOCROOT = $d;
no warnings 'once';
$Lazysite::Odoo::TRANSPORT = fake_shop();

bind( $d, id => 'quote', operation => 'shop.document', modes => 'public', params => 'name=name,size=size',
    answer => 'download', download_max_kb => 4 );

my $svc = oomd_start( sub { Lazysite::Daemon::Service::Oomd::run( docroot => $d ) } );
ok( wait_until( sub { oomd_up($d) }, 30 ), 'the real oomd is up' )
    or BAIL_OUT( 'oomd did not start: ' . Lazysite::Daemon::Service::Oomd::failure_reason($d) );

require "$root/lazysite-odoo.pl";

sub get {
    my ($query) = @_;
    my $out = '';
    {
        local %ENV = ( PATH => $ENV{PATH}, DOCUMENT_ROOT => $d, REQUEST_METHOD => 'GET', QUERY_STRING => $query,
            REMOTE_ADDR => '198.51.100.3', SCRIPT_NAME => '/cgi-bin/lazysite-odoo.pl', HTTP_HOST => 'localhost' );
        local *STDOUT;
        open STDOUT, '>', \$out or die $!;
        quiet( sub { main::main() } );
    }
    my ( $head, $body ) = split /\r\n\r\n/, $out, 2;
    my ($status) = $head =~ /Status:\s*(\d+)/;
    return ( $status // 0, $head, $body // '' );
}

my $DOC = "%PDF-1.4\n" . ( 'p' x 83 ) . "\x00\xFF\x80\r\n\r\n\x1a";

subtest 'the daemon\'s report is answered as the document' => sub {
    my ( $st, $h, $body ) = get('binding=quote&name=Quote+42.pdf');
    is( $st, 200, 'answered' ) or diag "$h\n$body";
    is( $body, $DOC, 'the bytes, whole' );
    like( $h, qr/^Content-Type: application\/pdf\r?$/m, 'the type' );
    like( $h, qr/^Content-Disposition: attachment; filename="Quote 42\.pdf"\r?$/m, 'and the name' );
    like( $h, qr/^Cache-Control: private, no-store\r?$/m, 'no-store' );
    my $last = ( Lazysite::Odoo::read_calls() || [] )->[0];
    is( $last->{via}, 'daemon', 'the call record says daemon: this was not the in-process path' );
};

subtest 'over the cap is refused on this path too' => sub {
    my ( $st, $h, $body ) = get('binding=quote&size=5000');
    is( $st, 413, 'status 413' );
    is( decode_json($body)->{kind}, 'too-large', 'too-large' );
    unlike( $body, qr/%PDF/, 'not a byte of the document' );
};

oomd_stop($svc);
done_testing();
