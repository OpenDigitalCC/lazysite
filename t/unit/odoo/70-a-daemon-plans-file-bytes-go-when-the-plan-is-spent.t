#!/usr/bin/perl
# SM1162: the purge of a spent plan's file bytes (t/unit/odoo/69) for a plan the
# DAEMON made. oomd keeps a planned file's bytes in its own run folder
# (lazysite/odoo/runs/<run_id>/blobs/) as well as lazysite's copy of the plan
# (lazysite/odoo/plans/<id>/blobs/); they go when the plan is confirmed or
# withdrawn, and the plan record keeps the file's sha256, name and size.
# The operation is a test pack (LazysiteTest::OdooOps::PhotoBlob) that holds a file in its
# plan as core.attach does, on the CLI fake's res.partner. THE REAL oomd, started as t/unit/odoo/61 and 67 start it, against OOM's fake Odoo.
use strict;
use warnings;
use Test::More;
use JSON::PP qw(decode_json);
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
$ENV{PERL5LIB} .= ':' . TestHelper::repo_root() . '/t/lib';    # the daemon loads this test pack too
my $d     = oomd_site( odoo_packs => 'LazysiteTest::OdooOps' );
$Lazysite::Odoo::DOCROOT = $d;
no warnings 'once';
$Lazysite::Odoo::TRANSPORT = fake_shop();

my $BYTES = "\xFF\xD8\xFF\xE0MARKER-oomd-blobs-" . ( 'q' x 300 );
my $SHA   = sha256_hex($BYTES);

bind( $d, id => 'att', operation => 'shop.photo_blob', modes => 'authenticated', callers => 'staff',
    file_params => 'f=photo', file_max_kb => 4 );

my %SAM = ( mode => 'authenticated', actor => 'sam', groups => ['staff'], caps => {}, ip => '192.0.2.5' );
sub slurp { open my $fh, '<:raw', $_[0] or return ''; local $/; return <$fh> }
sub plan_it {
    my ( undef, $r ) = quiet( sub {
            my ($b) = Lazysite::Odoo::find_binding('att');
            Lazysite::Odoo::call( $b, {}, %SAM, files => { f => [ { name => 'till.jpg', bytes => $BYTES } ] } );
    } );
    return $r;
}
sub nblobs { my $b = "$_[0]/blobs"; return -d $b ? scalar( () = glob("$b/*") ) : 0 }
sub dirs {
    my ($pid) = @_;
    my $plan = Lazysite::Odoo::plans_dir() . "/$pid";
    my $meta = decode_json( slurp("$plan/meta.json") );
    return ( $plan, "$d/lazysite/odoo/runs/$meta->{run_id}", $meta );
}

my $svc = oomd_start( sub { Lazysite::Daemon::Service::Oomd::run( docroot => $d ) } );
ok( wait_until( sub { oomd_up($d) }, 30 ), 'the real oomd is up' )
    or BAIL_OUT( 'oomd did not start: ' . Lazysite::Daemon::Service::Oomd::failure_reason($d) );

subtest 'a confirm removes the bytes from the daemon\'s run folder' => sub {
    my $r = plan_it();
    ok( $r->{planned}, 'planned' ) or diag explain $r;
    is( Lazysite::Odoo::last_via(), 'daemon', 'by the daemon' );
    my ( $plan, $run, $meta ) = dirs( $r->{plan} );
    ok( $meta->{run_id}, 'the plan names the daemon\'s run' );
    is( nblobs($plan), 0, 'lazysite\'s copy of a daemon-made plan holds no bytes (the daemon\'s run folder has them)' );
    is( nblobs($run),  1, 'and the daemon\'s run folder holds them' );
    my ( undef, $c ) = quiet( sub { Lazysite::Odoo::confirm( $r->{plan}, %SAM ) } );
    ok( $c->{ok} && $c->{applied}, 'confirmed and applied through the daemon' ) or diag explain $c;
    is( Lazysite::Odoo::last_via(), 'daemon', 'by the daemon' );
    ok( !-d "$plan/blobs", 'the plan folder\'s blobs/ is gone' );
    ok( !-d "$run/blobs",  'the daemon run folder\'s blobs/ is gone' );
    my $rec = slurp("$plan/plan.json");
    like( $rec, qr/\Q$SHA\E/,        'the plan record keeps the sha256' );
    like( $rec, qr/till\.jpg/,       'the name' );
    like( $rec, qr/"bytes"\s*:\s*\d+/, 'and the size' );
    ok( -e "$run/journal.jsonl" || -e "$plan/journal.jsonl", 'a journal is kept' );
};

subtest 'a withdraw removes the same two folders\' bytes' => sub {
    my $r = plan_it();
    my ( $plan, $run ) = dirs( $r->{plan} );
    is( nblobs($run), 1, 'the daemon holds them' );
    my ( undef, $w ) = quiet( sub { Lazysite::Odoo::withdraw( $r->{plan}, %SAM ) } );
    ok( $w->{ok} && $w->{withdrawn}, 'withdrawn' ) or diag explain $w;
    ok( !-d "$plan/blobs", 'the plan folder\'s blobs/ is gone' );
    ok( !-d "$run/blobs",  'the daemon run folder\'s blobs/ is gone' );
    like( slurp("$plan/plan.json"), qr/\Q$SHA\E/, 'the record keeps the sha256' );
};

oomd_stop($svc);
ok( !oomd_up($d), 'the daemon is stopped' );
done_testing();
