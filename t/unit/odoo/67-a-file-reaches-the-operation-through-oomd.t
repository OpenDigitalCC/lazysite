#!/usr/bin/perl
# SM1162: A FILE A BINDING TAKES REACHES THE OPERATION THROUGH THE REAL oomd.
#
# OOM 0.34's note: "On the oomd socket the client sends {name, base64, mimetype};
# the daemon decodes it. No path on the OOM host is needed." The binding hands the
# engine { name, bytes, mimetype }; the daemon client (Odoo::Ops::Client::Daemon,
# SM1164's path) puts it on the socket and the operation, in another process,
# sees the same bytes. The tell for the path is the answer's `via` and the
# operation's report of the sha256 of the bytes IT saw (OOM's test.file).
#
# THE REAL oomd runs here (t/vendor/oom/bin/oomd, started by the extension's
# service, as t/unit/odoo/61 does), against OOM's fake Odoo.
use strict;
use warnings;
use Test::More;
use File::Find ();
use Digest::SHA qw(sha256_hex);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper qw(repo_root);
use OdooTest   qw(oom_or_skip bind quiet fake_shop);

BEGIN { oom_or_skip() }
use OdooDaemonTest qw(oomd_site oomd_env oomd_start oomd_stop oomd_up wait_until);
use Lazysite::Odoo ();
use Lazysite::Daemon::Service::Oomd ();

my $state = oomd_env();
my $d     = oomd_site();
$Lazysite::Odoo::DOCROOT = $d;
no warnings 'once';
$Lazysite::Odoo::TRANSPORT = fake_shop();

my $MARK = 'MARKER-0c77f1-via-oomd';
my $JPEG = "\xFF\xD8\xFF\xE0$MARK" . ( 'j' x 400 );
my $PNG  = "\x89PNG\r\n\x1a\n$MARK" . ( 'p' x 400 );

bind( $d, id => 'filed', operation => 'test.file', modes => 'public',
    file_params => 'one=file,many=files', file_max_kb => 8, file_types => 'image/jpeg,image/png' );

sub run_b {
    my ( $id, $files ) = @_;
    my ( $log, $r ) = quiet( sub {
            my ($b) = Lazysite::Odoo::find_binding($id);
            Lazysite::Odoo::call( $b, {}, mode => 'public', ip => '192.0.2.7', files => $files );
    } );
    return ( $r, $log );
}

my $svc = oomd_start( sub { Lazysite::Daemon::Service::Oomd::run( docroot => $d ) } );
ok( wait_until( sub { oomd_up($d) }, 30 ), 'the real oomd is up' )
    or BAIL_OUT( 'oomd did not start: ' . Lazysite::Daemon::Service::Oomd::failure_reason($d) );

subtest 'a file and a list reach the operation in the daemon with their bytes' => sub {
    my ( $r, $log ) = run_b( 'filed', {
            one  => [ { name => 'receipt.jpg', bytes => $JPEG, claimed => 'image/jpeg' } ],
            many => [ { name => 'a.png', bytes => $PNG }, { name => 'b.jpg', bytes => $JPEG } ],
    } );
    ok( $r->{ok}, 'answered' ) or diag explain $r;
    is( Lazysite::Odoo::last_via(), 'daemon', 'by the daemon, not this process' );
    my @rows = @{ $r->{report}{rows} || [] };
    is( scalar @rows, 3, 'three files seen' );
    is_deeply( [ map { $_->{name} } @rows ], [qw(receipt.jpg a.png b.jpg)], 'by name' );
    is_deeply( [ map { $_->{seen} } @rows ], [ map { sha256_hex($_) } $JPEG, $PNG, $JPEG ],
        'each with the sha256 of the bytes the daemon\'s operation saw' );
    is_deeply( [ map { $_->{mimetype} } @rows ], [qw(image/jpeg image/png image/jpeg)], 'and the type read from the bytes' );
    unlike( $log, qr/\Q$MARK\E/, 'the log holds no bytes' );
    my $last = ( Lazysite::Odoo::read_calls() || [] )->[0];
    is( $last->{via}, 'daemon', 'the call record says daemon' );
    unlike( JSON::PP->new->encode($last), qr/\Q$MARK\E/, 'and holds no bytes' );
};

subtest 'a refusal never reaches the daemon' => sub {
    my ( $r ) = run_b( 'filed', { one => [ { name => 'x.pdf', bytes => "%PDF-1.4\n$MARK" } ] } );
    ok( !$r->{ok}, 'refused' );
    is( $r->{kind}, 'invalid', 'by the binding\'s type rule, in this process' );
    my ( $r2 ) = run_b( 'filed', { one => [ { name => 'big.jpg', bytes => "\xFF\xD8\xFF" . ( 'x' x 9000 ) } ] } );
    is( $r2->{kind}, 'too-large', 'over the binding\'s cap: too-large' );
};

subtest 'no file of the site holds the bytes' => sub {
    my @hits;
    File::Find::find( { no_chdir => 1, wanted => sub {
                return unless -f $_ && !-S $_;
                open my $fh, '<:raw', $_ or return;
                local $/;
                push @hits, $_ if index( <$fh>, $MARK ) >= 0;
    } }, $d );
    is_deeply( \@hits, [], 'under the site: nothing' ) or diag "@hits";
};

oomd_stop($svc);
done_testing();
