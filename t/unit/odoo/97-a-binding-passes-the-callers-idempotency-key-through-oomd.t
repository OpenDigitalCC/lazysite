#!/usr/bin/perl
# SM1223 through the real oomd: the caller's Idempotency-Key is made OOM's idem (the
# binding, who sent it and the key, hashed) on the run, the approve and the apply, so
# oomd's own registry (the runs folder's .idem) holds it and a repeat is OOM's repeat:
# the first plan or the first result, nothing sent to Odoo again. In-process is
# t/unit/odoo/96. The pack LazysiteTest::OdooMade makes a partner in oomd's world.
use strict;
use warnings;
use Test::More;
use JSON::PP ();
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper qw(repo_root);
use OdooTest   qw(oom_or_skip bind quiet);

BEGIN { oom_or_skip() }
use OdooDaemonTest qw(oomd_site oomd_env oomd_start oomd_stop oomd_up wait_until);
use Lazysite::Odoo ();
use Lazysite::Odoo::Visitor         ();
use Lazysite::Daemon::Service::Oomd ();

my $state = oomd_env();
my $PACK = 'LazysiteTest::OdooMade'; # quoted alone so tools/precheck-areas.pl sees the test use it
$ENV{ODOO_OPS_NAMESPACES} = $PACK;
$ENV{PERL5LIB} .= ':' . repo_root() . '/t/lib';
my $d = oomd_site( odoo_packs => $PACK );
$Lazysite::Odoo::DOCROOT          = $d;
$Lazysite::Odoo::Visitor::DOCROOT = $d;

bind( $d, id => 'make_now', operation => 'test.make', modes => 'public,authenticated', callers => 'staff',
    apply => 'immediate', params => 'name=name' );
bind( $d, id => 'make_later', operation => 'test.make', modes => 'authenticated', callers => 'staff',
    params => 'name=name' );

my %SAM = ( mode => 'authenticated', actor => 'sam', caps => {}, groups => ['staff'], ip => '192.0.2.7' );
my %ALICE = ( mode => 'authenticated', actor => 'alice', caps => {}, groups => ['staff'], ip => '192.0.2.8' );
my ($VA) = Lazysite::Odoo::Visitor::mint();

sub call_b {
    my ( $id, $in, %ctx ) = @_;
    my ( undef, $r ) = quiet( sub {
            my ($b) = Lazysite::Odoo::find_binding($id);
            Lazysite::Odoo::call( $b, $in, %ctx );
    } );
    return $r;
}
sub confirm_p {
    my ( $plan, %ctx ) = @_;
    my ( undef, $r )   = quiet( sub { Lazysite::Odoo::confirm( $plan, %ctx ) } );
    return $r;
}
sub partners {
    open my $fh, '<', "$state/state.json" or return 2; # the seed, before oomd has kept anything
    my $s = JSON::PP->new->decode( do { local $/; <$fh> } );
    return scalar keys %{ $s->{data}{'res.partner'} // {} };
}
sub idem_files {
    opendir my $dh, "$d/lazysite/odoo/runs/.idem" or return 0;
    return scalar grep { !/\A\./ } readdir $dh;
}
sub plan_dirs { opendir my $dh, "$d/lazysite/odoo/plans" or return 0; return scalar grep { /\A[0-9a-f]{32}\z/ } readdir $dh }

my $svc = oomd_start( sub { Lazysite::Daemon::Service::Oomd::run( docroot => $d ) } );
ok( wait_until( sub { oomd_up($d) }, 30 ), 'the real oomd is up' )
    or BAIL_OUT( 'oomd did not start: ' . Lazysite::Daemon::Service::Oomd::failure_reason($d) );

subtest 'a repeat with the same key does not write twice (immediate apply)' => sub {
    my $n0 = partners();
    my $a = call_b( 'make_now', { name => 'Queued' }, %SAM, idem_key => 'queue-item-0001-aaaa' );
    is( Lazysite::Odoo::last_via(), 'daemon', 'it went through oomd' );
    ok( $a->{applied}, 'the first applies' ) or diag explain $a;
    ok( !$a->{repeat}, 'and is not a repeat' );
    is( partners(),   $n0 + 1, 'one partner made' );
    is( idem_files(), 1,       'oomd holds the key (its .idem registry)' );
    my $b = call_b( 'make_now', { name => 'Queued' }, %SAM, idem_key => 'queue-item-0001-aaaa' );
    is( Lazysite::Odoo::last_via(), 'daemon', 'the repeat went through oomd too' );
    ok( $b->{ok} && $b->{applied} && $b->{repeat}, 'the repeat is OOM\'s repeat' ) or diag explain $b;
    is( $b->{plan}, $a->{plan}, 'of the same plan' );
    is_deeply( $b->{result}{created}, $a->{result}{created}, 'with the first result (the id it made)' );
    is( partners(),   $n0 + 1, 'nothing was made again' );
    is( idem_files(), 1,       'and no second key' );
};

subtest 'the same key with other parameters is refused by OOM and writes nothing' => sub {
    my $n0 = partners();
    my $r = call_b( 'make_now', { name => 'Other' }, %SAM, idem_key => 'queue-item-0001-aaaa' );
    is( $r->{kind}, 'refused', 'refused' ) or diag explain $r;
    like( $r->{error}, qr/different request/, 'saying why' );
    is( partners(), $n0, 'nothing made' );
};

subtest 'two persons with the same key do not collide' => sub {
    my $n0  = partners();
    my $key = 'shared-by-two-9999';
    my $sam = call_b( 'make_now', { name => 'FromSam' }, %SAM, idem_key => $key );
    my $al  = call_b( 'make_now', { name => 'FromAlice' }, %ALICE, idem_key => $key );
    my $vi = call_b( 'make_now', { name => 'FromVisitor' }, mode => 'public', visitor_key => $VA, ip => '192.0.2.9', idem_key => $key );
    ok( $sam->{applied} && !$sam->{repeat}, 'sam: applied' ) or diag explain $sam;
    ok( $al->{applied} && !$al->{repeat}, 'alice, same key: applied (not refused as a different request)' ) or diag explain $al;
    ok( $vi->{applied} && !$vi->{repeat}, 'a visitor, same key: applied' ) or diag explain $vi;
    is( partners(), $n0 + 3, 'three partners made' );
    ok( call_b( 'make_now', { name => 'FromAlice' }, %ALICE, idem_key => $key )->{repeat}, 'alice\'s repeat is a repeat' );
    ok( call_b( 'make_now', { name => 'FromSam' }, %SAM, idem_key => $key )->{repeat}, 'sam\'s repeat is a repeat' );
    is( partners(), $n0 + 3, 'nothing made again' );
};

subtest 'a bad key is refused before oomd is asked' => sub {
    my $n0 = partners();
    my $f0 = idem_files();
    for my $bad ( 'abc', 'k' x 129, 'has space in it', '' ) {
        my $r = call_b( 'make_now', { name => 'Bad' }, %SAM, idem_key => $bad );
        is( $r->{kind}, 'invalid', 'refused as invalid' ) or diag explain $r;
    }
    is( partners(),   $n0, 'nothing made' );
    is( idem_files(), $f0, 'and oomd was given no key' );
};

subtest 'a plan made with a key, a repeat of it, and a confirm sent twice' => sub {
    my $key = 'plan-item-0002-bbbb';
    my $n0  = partners();
    my $p   = call_b( 'make_later', { name => 'Planned' }, %SAM, idem_key => $key );
    ok( $p->{planned}, 'a plan' ) or diag explain $p;
    my $dirs = plan_dirs();
    my $p2   = call_b( 'make_later', { name => 'Planned' }, %SAM, idem_key => $key );
    is( Lazysite::Odoo::last_via(), 'daemon', 'through oomd' );
    ok( $p2->{planned} && $p2->{repeat}, 'the repeat is a repeat' ) or diag explain $p2;
    is( $p2->{plan}, $p->{plan}, 'of the same plan' );
    is( plan_dirs(), $dirs,      'no second folder' );
    is( partners(),  $n0,        'nothing written by planning' );

    my $c = confirm_p( $p->{plan}, %SAM );
    is( Lazysite::Odoo::last_via(), 'daemon', 'the confirm went through oomd' );
    ok( $c->{ok} && $c->{applied} && !$c->{repeat}, 'its maker confirms it' ) or diag explain $c;
    is( partners(), $n0 + 1, 'one partner made' );
    my $c2 = confirm_p( $p->{plan}, %SAM );
    ok( $c2->{ok} && $c2->{applied} && $c2->{repeat}, 'a second confirm answers the first result' ) or diag explain $c2;
    is_deeply( $c2->{result}{created}, $c->{result}{created}, 'the id it made' );
    is( partners(), $n0 + 1, 'nothing made again' );
    my $p3 = call_b( 'make_later', { name => 'Planned' }, %SAM, idem_key => $key );
    ok( $p3->{applied} && $p3->{repeat}, 'the key after the apply answers the result, not a new plan' ) or diag explain $p3;
    is( partners(),                              $n0 + 1, 'still nothing made' );
    is( confirm_p( $p->{plan}, %ALICE )->{kind}, 'not-found', 'another person cannot confirm it' );
};

subtest 'a withdrawn plan\'s key is not reused for its plan' => sub {
    my $key = 'plan-item-0003-cccc';
    my $p   = call_b( 'make_later', { name => 'Withdrawn' }, %SAM, idem_key => $key );
    ok( $p->{planned}, 'a plan' ) or diag explain $p;
    my ( undef, $w ) = quiet( sub { Lazysite::Odoo::withdraw( $p->{plan}, %SAM ) } );
    ok( $w->{withdrawn}, 'withdrawn' ) or diag explain $w;
    my $r = call_b( 'make_later', { name => 'Withdrawn' }, %SAM, idem_key => $key );
    is( $r->{kind}, 'refused', 'the key is refused' ) or diag explain $r;
    like( $r->{error}, qr/withdrawn/, 'saying the plan was withdrawn' );
};

subtest 'the record names the key OOM holds and a repeat' => sub {
    my $rows  = Lazysite::Odoo::read_calls();
    my @keyed = grep { defined $_->{idem} } @$rows;
    ok( scalar @keyed, 'calls carry an idem' );
    is( scalar( grep { $_->{idem} !~ /\Alz1-[0-9a-f]{64}\z/ } @keyed ), 0, 'each a lz1- hash' );
    ok( scalar( grep { $_->{repeat} && $_->{via} eq 'daemon' } @$rows ), 'a repeat through the daemon is marked' );
    unlike( JSON::PP->new->encode($rows), qr/queue-item-0001|shared-by-two|plan-item-000/, 'the caller\'s own key is in no record' );
};

oomd_stop($svc);
done_testing;
