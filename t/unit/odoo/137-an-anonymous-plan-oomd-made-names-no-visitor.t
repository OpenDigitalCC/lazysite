#!/usr/bin/perl
# SM1395 (ruling 160) through the real oomd: a plan the daemon makes for an
# anonymous public binding is kept twice, in lazysite's plan folder and in the
# daemon's run folder (lazysite/odoo/runs/<run_id>/), and both name the visitor
# as visitor:<hash> - meta.json's owner, run.json's planned/approval/applied
# `by`, the journal's and OOM's audit's actor. Once the plan is spent each is
# `visitor` with no hash, and the parameters are null, in both folders; the
# maker's confirm, which checks the owner before the plan is spent, still works.
# In-process is t/unit/odoo/139. The pack LazysiteTest::OdooMade makes a partner
# in oomd's world.
#
# Ruling 168: a repeat of the spent plan's confirm with the same Idempotency-Key
# gets the daemon's first outcome, from its run folder, naming no hash.
#
# Reverted, the hash and the name sent stay in both folders; with ruling 168's
# pass reverted, the repeat is not found.
use strict;
use warnings;
use Test::More;
use JSON::PP qw(decode_json);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper qw(repo_root);
use OdooTest   qw(oom_or_skip bind quiet);

BEGIN { oom_or_skip() }
use OdooDaemonTest qw(oomd_site oomd_env oomd_start oomd_stop oomd_up wait_until);
use Lazysite::Odoo                  ();
use Lazysite::Odoo::Visitor         ();
use Lazysite::Daemon::Service::Oomd ();

my $state = oomd_env();
my $PACK  = 'LazysiteTest::OdooMade';    # quoted alone so tools/precheck-areas.pl sees the test use it
$ENV{ODOO_OPS_NAMESPACES} = $PACK;
$ENV{PERL5LIB} .= ':' . repo_root() . '/t/lib';
my $d = oomd_site( odoo_packs => $PACK );
$Lazysite::Odoo::DOCROOT          = $d;
$Lazysite::Odoo::Visitor::DOCROOT = $d;

bind( $d, id => 'anon_later', operation => 'test.make', modes => 'public', apply => 'confirm', anonymous => 1,
    params => 'name=name' );
bind( $d, id => 'anon_now', operation => 'test.make', modes => 'public', apply => 'immediate', anonymous => 1,
    params => 'name=name' );

my $IP = '192.0.2.31';
sub slurp { open my $fh, '<:raw', $_[0] or return ''; local $/; return scalar <$fh> }
sub call_b {
    my ( $id, $in, %ctx ) = @_;
    my ( undef, $r ) = quiet( sub {
            my ($b) = Lazysite::Odoo::find_binding($id);
            Lazysite::Odoo::call( $b, $in, mode => 'public', ip => $IP, %ctx );
    } );
    return $r;
}
sub folders {
    my ($pid) = @_;
    my $plan = Lazysite::Odoo::plans_dir() . "/$pid";
    my $meta = decode_json( slurp("$plan/meta.json") );
    return ( $plan, "$d/lazysite/odoo/runs/$meta->{run_id}", $meta );
}

# every file under the folders that holds one of the strings
sub holding {
    my ( $dirs, @s ) = @_;
    my $alt = join '|', map {quotemeta} @s;
    my @hit;
    require File::Find;
    File::Find::find( { no_chdir => 1, wanted => sub { push @hit, $_ if -f $_ && slurp($_) =~ /$alt/ } },
        grep { -d } @$dirs );
    return @{ [ sort @hit ] };
}

my $svc = oomd_start( sub { Lazysite::Daemon::Service::Oomd::run( docroot => $d ) } );
ok( wait_until( sub { oomd_up($d) }, 30 ), 'the real oomd is up' )
    or BAIL_OUT( 'oomd did not start: ' . Lazysite::Daemon::Service::Oomd::failure_reason($d) );

subtest 'a confirmed plan: the hash is kept until the confirm, then gone from both folders' => sub {
    my ($key) = Lazysite::Odoo::Visitor::mint();
    my $hash = Lazysite::Odoo::Visitor::visitor_id($key);
    my $p    = call_b( 'anon_later', { name => 'Anon-Later-Name' }, visitor_key => $key );
    ok( $p->{planned}, 'planned' ) or diag explain $p;
    is( Lazysite::Odoo::last_via(), 'daemon', 'by the daemon' );
    my ( $plan, $run, $meta ) = folders( $p->{plan} );
    ok( $meta->{run_id} && -d $run, 'the plan names the daemon\'s run, and its folder is there' );
    is( $meta->{owner}, "visitor:$hash", 'until it is spent the owner names the visitor' );
    ok( scalar holding( [$run], $hash ), 'and the daemon\'s run folder names the hash' )
        or diag explain [ $hash, map { ( $_ => slurp($_) ) } glob("$run/*") ];
    my ( undef, $c ) = quiet( sub { Lazysite::Odoo::confirm( $p->{plan}, mode => 'public', visitor_key => $key, ip => $IP ) } );
    ok( $c->{ok} && $c->{applied}, 'the maker\'s confirm still works' ) or diag explain $c;
    is( Lazysite::Odoo::last_via(), 'daemon', 'by the daemon' );
    is( decode_json( slurp("$plan/meta.json") )->{owner}, 'visitor', 'then the owner is visitor alone' );
    my @h = holding( [ $plan, $run ], $hash );
    is_deeply( \@h, [], 'no record in either folder names the hash' ) or diag explain \@h;
    my @v = holding( [ $plan, $run ], 'Anon-Later-Name' );
    is_deeply( \@v, [], 'nor the name sent' ) or diag explain \@v;
    like( slurp("$run/run.json"), qr/"by"\s*:\s*"visitor"/, 'the run record keeps who: a visitor' );
};

subtest 'an immediate apply: the same, as it answers' => sub {
    my ($key) = Lazysite::Odoo::Visitor::mint();
    my $hash = Lazysite::Odoo::Visitor::visitor_id($key);
    my $r    = call_b( 'anon_now', { name => 'Anon-Now-Name' }, visitor_key => $key );
    ok( $r->{ok} && $r->{applied}, 'applied' ) or diag explain $r;
    is( Lazysite::Odoo::last_via(), 'daemon', 'by the daemon' );
    my ( $plan, $run ) = folders( $r->{plan} );
    is( decode_json( slurp("$plan/meta.json") )->{owner}, 'visitor', 'the owner is visitor alone' );
    my @h = holding( [ $plan, $run ], $hash );
    is_deeply( \@h, [], 'no record in either folder names the hash' ) or diag explain \@h;
    my @v = holding( [ $plan, $run ], 'Anon-Now-Name' );
    is_deeply( \@v, [], 'nor the name sent' ) or diag explain \@v;
};

# SM1395 (ruling 168): a repeat of a spent plan's confirm with the same
# Idempotency-Key gets the first stored outcome - here the daemon's, from its run
# folder - and nothing in either folder, the call record or the audit names the
# hash. Without the key, not found. In-process, and the withdraw: t/unit/odoo/138.
subtest 'a repeated confirm with the key gets the daemon\'s first outcome' => sub {
    my ($key) = Lazysite::Odoo::Visitor::mint();
    my $hash = Lazysite::Odoo::Visitor::visitor_id($key);
    my $K    = 'queue-item-137-confirm';
    my $p    = call_b( 'anon_later', { name => 'Anon-Again-Name' }, visitor_key => $key, idem_key => $K );
    ok( $p->{planned}, 'planned with a key' ) or diag explain $p;
    my %cc = ( mode => 'public', visitor_key => $key, ip => $IP, idem_key => $K );
    my ( undef, $c ) = quiet( sub { Lazysite::Odoo::confirm( $p->{plan}, %cc ) } );
    ok( $c->{ok} && $c->{applied}, 'the confirm applied' ) or diag explain $c;
    is( Lazysite::Odoo::last_via(), 'daemon', 'by the daemon' );
    my ( $plan, $run ) = folders( $p->{plan} );
    ok( -f "$run/result.json" && !-f "$plan/result.json", 'the outcome is kept in the daemon\'s run folder' );
    my ( undef, $again ) = quiet( sub { Lazysite::Odoo::confirm( $p->{plan}, %cc ) } );
    ok( $again->{ok} && $again->{applied} && $again->{repeat}, 'the repeat gets the first outcome' )
        or diag explain $again;
    is_deeply( $again->{result}{counts}, $c->{result}{counts}, 'its counts' );
    my ( undef, $bare ) = quiet( sub { Lazysite::Odoo::confirm( $p->{plan}, %cc, idem_key => undef ) } );
    is( $bare->{kind}, 'not-found', 'without the key, not found' ) or diag explain $bare;
    my @h = holding( [ $plan, $run ], $hash, 'Anon-Again-Name' );
    is_deeply( \@h, [], 'no record in either folder names the hash or the name sent' ) or diag explain \@h;
    unlike( slurp( Lazysite::Odoo::calls_file() ), qr/\Q$hash\E/, 'no call line names the hash' );
    unlike( slurp("$d/lazysite/logs/audit.log"), qr/\Q$hash\E/, 'nor the audit' );
};

oomd_stop($svc);
done_testing;
