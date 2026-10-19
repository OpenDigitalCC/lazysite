#!/usr/bin/perl
# SM1193 through the real oomd (as t/unit/odoo/61 runs it): the daemon client returns
# the same result, so an apply Odoo refuses answers apply-incomplete with the
# change's key, model, action and Odoo's message, for an immediate apply and for a
# confirm. OOM's own Odoo::Test::Ops::Fail is the refusing operation; its `why`
# parameter is the message Odoo gives.
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
my $FAIL_PACK = 'LazysiteTest::OdooFail';    # quoted alone so tools/precheck-areas.pl sees the test use it
$ENV{ODOO_OPS_NAMESPACES} = "Odoo::Test::Ops,Odoo::Test::OomdOps,$FAIL_PACK";
$ENV{PERL5LIB} .= ':' . TestHelper::repo_root() . '/t/lib';    # the daemon loads the SM1198 test pack too
my $d = oomd_site( odoo_packs => "Odoo::Test::Ops,Odoo::Test::OomdOps,$FAIL_PACK" );
$Lazysite::Odoo::DOCROOT = $d;
no warnings 'once';
$Lazysite::Odoo::TRANSPORT = fake_shop();

bind( $d, id => 'refuse', operation => 'test.fail', modes => 'authenticated', callers => 'staff',
    apply => 'immediate', params => 'why=why' );
bind( $d, id => 'coded', operation => 'test.refuse', modes => 'authenticated', callers => 'staff',
    apply => 'immediate', params => 'why=why' );
bind( $d, id => 'refuse_later', operation => 'test.fail', modes => 'authenticated', callers => 'staff',
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
sub the_change { my ($r) = @_; return ( grep { ( $_->{outcome} // '' ) eq 'failed' } @{ $r->{result}{changes} || [] } )[0] }

my $svc = oomd_start( sub { Lazysite::Daemon::Service::Oomd::run( docroot => $d ) } );
ok( wait_until( sub { oomd_up($d) }, 30 ), 'the real oomd is up' )
    or BAIL_OUT( 'oomd did not start: ' . Lazysite::Daemon::Service::Oomd::failure_reason($d) );

subtest 'an immediate apply Odoo refuses says which change and why' => sub {
    my $r = run_b( 'refuse', { why => 'The period is closed' } );
    is( Lazysite::Odoo::last_via(), 'daemon', 'it went through the daemon' );
    is( $r->{kind}, 'apply-incomplete', 'apply-incomplete' ) or diag explain $r;
    my $c = the_change($r) or BAIL_OUT('no failed change');
    is( $c->{key}, 'refuse:7', 'key' );
    is( $c->{model}, 'purchase.order', 'model' );
    is( $c->{action}, 'custom', 'action' );
    is( $c->{message}, 'The period is closed', "Odoo's message" );
};

subtest 'a confirm says the same' => sub {
    my $p = run_b( 'refuse_later', { why => 'Closed for the year' } );
    ok( $p->{planned}, 'planned' ) or diag explain $p;
    my ( undef, $c ) = quiet( sub { Lazysite::Odoo::confirm( $p->{plan}, %WHO ) } );
    is( Lazysite::Odoo::last_via(), 'daemon', 'through the daemon' );
    is( $c->{kind}, 'apply-incomplete', 'apply-incomplete' ) or diag explain $c;
    is( the_change($c)->{message}, 'Closed for the year', "Odoo's message" );
};

subtest 'a message with a path is withheld through the daemon too' => sub {
    my $r = run_b( 'refuse', { why => 'cannot write /var/lib/odoo/filestore/x' } );
    my $c = the_change($r);
    ok( $c->{withheld}, 'withheld' ) or diag explain $r;
    unlike( $c->{message}, qr{/var}, 'the path is not in it' );
};

# SM1198 (inbox 2026-10-19-oom-0.36-acting-shop-rows.md: "`failed_changes` now also
# carries a refusal's `code`"). lazysite's side is proved without OOM: a failed entry
# that has a code puts it on the answer's change (SM1193's pass-through), and one that
# has none leaves it off.
subtest 'a failed change\'s code, when the entry has one, reaches the change' => sub {
    my @changes = ( { seq => 1, action => 'custom', outcome => 'done' }, { seq => 2, action => 'custom', outcome => 'done' } );
    Lazysite::Odoo::_add_failures( \@changes,
        [ { seq => 1, key => 'a:1', model => 'x', message => 'No.', code => 'not-yours' }, { seq => 2, key => 'b:2', model => 'x', message => 'No.' } ] );
    is( $changes[0]{code}, 'not-yours', 'the code is on the change' );
    ok( !exists $changes[1]{code}, 'and nothing is invented when the entry has none' );
};

# End to end, through the real oomd and a change refused with kind `refused`, code
# `not-yours`. OOM 0.36's Runner journals that code in the entry's `error`, but its
# `push @failed` (Runner.pm, "id => ..., message => ...") adds NO code, so the
# 0.36 answer has none to carry (the inbox note says it does; reported to the OOM
# agent). TODO, not skip: the day OOM adds it this test says so, and the line below
# becomes an ordinary `is`.
subtest 'a refusal\'s code through oomd' => sub {
    my $r = run_b( 'coded', { why => 'Not yours' } );
    is( $r->{kind}, 'apply-incomplete', 'apply-incomplete' ) or diag explain $r;
    my $c = the_change($r) or BAIL_OUT('no failed change');
    is( $c->{message}, 'Not yours', 'its message arrives' );
  TODO: {
        local $TODO = 'OOM 0.36 failed_changes carries no code (Runner.pm push @failed)';
        is( $c->{code}, 'not-yours', 'and its code' );
    }
};

oomd_stop($svc);
done_testing();
