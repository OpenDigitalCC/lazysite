#!/usr/bin/perl
# SM1218 through the real oomd: a write whose request was sent and got no answer
# (OOM 0.38 records it unknown) answers apply-incomplete with unknown => 1, the
# change's outcome unknown with its key, message and OOM's reason, for an immediate
# apply and for a confirm. LazysiteTest::OdooFail::Timeout is the pack: its one
# change throws a transport error that was sent and was a write. Nothing is written.
use strict;
use warnings;
use Test::More;
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
$ENV{PERL5LIB} .= ':' . TestHelper::repo_root() . '/t/lib'; # the daemon loads the SM1198 test pack too
my $d = oomd_site( odoo_packs => "Odoo::Test::Ops,Odoo::Test::OomdOps,$FAIL_PACK" );
$Lazysite::Odoo::DOCROOT = $d;
no warnings 'once';
$Lazysite::Odoo::TRANSPORT = fake_shop();

bind( $d, id => 'timeout', operation => 'test.timeout', modes => 'authenticated', callers => 'staff',
    apply => 'immediate', params => 'why=why' );
bind( $d, id => 'timeout_later', operation => 'test.timeout', modes => 'authenticated', callers => 'staff',
    params => 'why=why' );
my %WHO = ( mode => 'authenticated', actor => 'alice', caps => { manage_connectors => 1 }, groups => ['staff'], ip => '192.0.2.7' );

sub run_b {
    my ( $id, $in, %ctx ) = @_;
    my ( undef, $r ) = quiet( sub {
            my ($b) = Lazysite::Odoo::find_binding($id);
            Lazysite::Odoo::call( $b, $in // {}, %WHO, %ctx );
    } );
    return $r;
}
sub the_change { my ($r) = @_; return ( grep { ( $_->{outcome} // '' ) eq 'unknown' } @{ $r->{result}{changes} || [] } )[0] }

my $svc = oomd_start( sub { Lazysite::Daemon::Service::Oomd::run( docroot => $d ) } );
ok( wait_until( sub { oomd_up($d) }, 30 ), 'the real oomd is up' )
    or BAIL_OUT( 'oomd did not start: ' . Lazysite::Daemon::Service::Oomd::failure_reason($d) );

sub says_unknown {
    my ( $r, $label ) = @_;
    is( $r->{kind}, 'apply-incomplete',   "$label: apply-incomplete" ) or diag explain $r;
    is( $r->{unknown},                 1, "$label: unknown => 1" );
    is( $r->{result}{counts}{unknown}, 1, "$label: counts.unknown" );
    ok( !$r->{result}{counts}{failed}, "$label: not counted failed" );
    my $c = the_change($r) or BAIL_OUT("$label: no unknown change");
    ok( $c->{unknown}, "$label: flagged" );
    is( $c->{key},   'submit:81',          "$label: key" );
    is( $c->{model}, 'hr_timesheet.sheet', "$label: model" );
    like( $c->{reason},  qr/may have made/, "$label: OOM's reason" );
    like( $c->{message}, qr/Timed out/,     "$label: the transport's message" );
    like( $r->{error},   qr/not known whether Odoo made it/, "$label: the sentence" );
    unlike( $r->{error}, qr/\b(?:failed|try again|retry)\b/i, "$label: no failed, no retry advice" );
}

subtest 'an immediate apply with no answer says the outcome is not known' => sub {
    my $r = run_b( 'timeout', {} );
    is( Lazysite::Odoo::last_via(), 'daemon', 'it went through the daemon' );
    says_unknown( $r, 'immediate' );
};

subtest 'a confirm says the same' => sub {
    my $p = run_b( 'timeout_later', {} );
    ok( $p->{planned}, 'planned' ) or diag explain $p;
    my ( undef, $c ) = quiet( sub { Lazysite::Odoo::confirm( $p->{plan}, %WHO ) } );
    is( Lazysite::Odoo::last_via(), 'daemon', 'through the daemon' );
    says_unknown( $c, 'confirm' );
};

subtest 'a reason with a path is not passed' => sub {
    my $r = run_b( 'timeout', { why => 'read timeout on /var/run/odoo/x.sock' } );
    my $c = the_change($r) or BAIL_OUT('no unknown change');
    ok( $c->{withheld}, 'the message is withheld' ) or diag explain $r;
    unlike( join( ' ', map { $_ // '' } values %$c ), qr{/var}, 'no path in the change' );
};

oomd_stop($svc);
done_testing();
