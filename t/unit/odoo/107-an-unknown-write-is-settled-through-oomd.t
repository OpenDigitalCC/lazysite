#!/usr/bin/perl
# SM1275 through the real oomd: a run oomd applied that left a change unknown is
# resumed by oomd's own resume (Calls->resume of the daemon run's journal), and the
# plan it makes is approved and applied there, as a confirm's is. The read-back
# comes first: LazysiteTest::OdooFail::Settle's handler says whether its change was
# made; LazysiteTest::OdooFail::Timeout's names no read, so the resume is refused
# `unknown-outcome` until its maker says. A change assumed not made is sent again,
# ends unknown again, and is a run of its own, named in the answer.
use strict;
use warnings;
use Test::More;
use JSON::PP qw(encode_json);
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
my $FAIL_PACK = 'LazysiteTest::OdooFail'; # quoted alone so tools/precheck-areas.pl sees the test use it
$ENV{ODOO_OPS_NAMESPACES} = "Odoo::Test::Ops,Odoo::Test::OomdOps,$FAIL_PACK";
$ENV{PERL5LIB} .= ':' . TestHelper::repo_root() . '/t/lib'; # the daemon loads the test pack too
my $d = oomd_site( odoo_packs => "Odoo::Test::Ops,Odoo::Test::OomdOps,$FAIL_PACK" );
$Lazysite::Odoo::DOCROOT = $d;
no warnings 'once';
$Lazysite::Odoo::TRANSPORT = fake_shop();

bind( $d, id => 'timeout', operation => 'test.timeout', modes => 'authenticated', callers => 'staff',
    apply => 'immediate' );
bind( $d, id => 'settle', operation => 'test.settle', modes => 'authenticated', callers => 'staff',
    apply => 'immediate', params => 'made=made' );
my %WHO = ( mode => 'authenticated', actor => 'alice', caps => {}, groups => ['staff'], ip => '192.0.2.7' );

sub run_b {
    my ( $id, $in ) = @_;
    my ( undef, $r ) = quiet( sub {
            my ($b) = Lazysite::Odoo::find_binding($id);
            Lazysite::Odoo::call( $b, $in // {}, %WHO );
    } );
    return $r;
}
sub resume_as {
    my ( $run, %o ) = @_;
    my ( undef, $r ) = quiet( sub { Lazysite::Odoo::resume( $run, %WHO, %o ) } );
    return $r;
}

my $svc = oomd_start( sub { Lazysite::Daemon::Service::Oomd::run( docroot => $d ) } );
ok( wait_until( sub { oomd_up($d) }, 30 ), 'the real oomd is up' )
    or BAIL_OUT( 'oomd did not start: ' . Lazysite::Daemon::Service::Oomd::failure_reason($d) );

subtest 'found made by its handler: settled, nothing sent again' => sub {
    my $r = run_b( 'settle', { made => 1 } );
    is( Lazysite::Odoo::last_via(), 'daemon', 'the apply went through the daemon' );
    is( $r->{unknown}, 1, 'unknown' ) or diag explain $r;
    like( $r->{run} // '', qr/\A[0-9a-f]{32}\z/, 'the run is named' );
    my $s = resume_as( $r->{run} );
    is( Lazysite::Odoo::last_via(), 'daemon', 'the resume went through the daemon' );
    ok( $s->{ok}, 'settled' ) or diag explain $s;
    is( $s->{settled}[0]{how},     'read', 'by reading it back' );
    is( $s->{settled}[0]{outcome}, 'done', 'as made' );
    is( $s->{result}{total}, 0, 'nothing left to apply' );
    unlike( encode_json($s), qr{/lazysite/|journal\.jsonl}, 'no host path in the answer' );
    is( resume_as( $r->{run} )->{kind}, 'settled', 'and it is not resumed twice' );
};

subtest 'no read tells: refused until its maker says, then settled' => sub {
    my $r = run_b('timeout');
    is( $r->{unknown}, 1, 'unknown' ) or diag explain $r;
    my $c = resume_as( $r->{run} );
    is( Lazysite::Odoo::last_via(), 'daemon', 'through the daemon' );
    is( $c->{kind}, 'unknown-outcome', 'refused by name' ) or diag explain $c;
    is_deeply( [ map { $_->{key} } @{ $c->{changes} } ], ['submit:81'], 'naming the change' );
    my $s = resume_as( $r->{run}, assume_done => ['submit:81'] );
    ok( $s->{ok}, 'assumed made: settled' ) or diag explain $s;
    is( $s->{settled}[0]{how}, 'assumed', 'by its maker\'s word' );
};

subtest 'assumed not made: sent again, unknown again, a run of its own' => sub {
    my $r = run_b('timeout');
    my $s = resume_as( $r->{run}, assume_not_done => ['submit:81'] );
    is( Lazysite::Odoo::last_via(), 'daemon', 'through the daemon' );
    is( $s->{kind},    'apply-incomplete', 'the change was sent again and got no answer' ) or diag explain $s;
    is( $s->{unknown}, 1,                  'unknown again' );
    like( $s->{run} // '', qr/\A[0-9a-f]{32}\z/, 'the resumed run is named' );
    isnt( $s->{run}, $r->{run}, 'and is not the first' );
    is( resume_as( $r->{run} )->{kind}, 'settled', 'the first is settled' );
    is( resume_as( $s->{run} )->{kind}, 'unknown-outcome', 'the second is open' );
};

oomd_stop($svc);
done_testing();
