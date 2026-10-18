#!/usr/bin/perl
# SM1164 D3: EVERY ENGINE CALL GOES THROUGH THE DAEMON CLIENT WHEN THE DAEMON PATH
# IS ON; `via` IS IN THE CALL RECORD; SM1144'S `call` PHASE SAYS oomd OR in-process.
#
# Inbox L7 addendum: "The call path through Odoo::Ops::Client::Daemon, with the
# in-process fallback, and `via` in the call record." OOM's answers (0.31): `fallback
# => 0` makes a down daemon die `transport`/`daemon-down`; every answer carries `via`;
# "the actor recorded on an approval is the request's actor, so send actor on approve
# as well as on run"; "a person's session id goes with each request; oomd keeps it
# nowhere".
#
# THE REAL oomd (t/vendor/oom/bin/oomd) runs here, started by the service this
# extension adds, against OOM's fake Odoo. The tell for which path answered is
# oomd.pid, an operation OOM ships for the tests of the daemon: it reports the pid of
# the process that ran it, so a daemon answer has a pid that is not this test's.
use strict;
use warnings;
use Test::More;
use File::Find ();
use JSON::PP   ();
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper qw(repo_root);
use OdooTest   qw(oom_or_skip bind quiet fake_shop write_conf);

BEGIN { oom_or_skip() }
use OdooDaemonTest qw(oomd_site oomd_env oomd_start oomd_stop oomd_up wait_until);
use Lazysite::Odoo  ();
use Lazysite::Timing ();
use Lazysite::Daemon::Service::Oomd ();

my $root  = repo_root();
my $state = oomd_env();
my $d     = oomd_site();
$Lazysite::Odoo::DOCROOT = $d;
no warnings 'once';
$Lazysite::Odoo::TRANSPORT = fake_shop();    # the in-process path's Odoo; the daemon has CliFake

bind( $d, id => 'who', operation => 'oomd.pid', modes => 'public', params => 'e=echo' );
bind( $d, id => 'mine', operation => 'oomd.pid', modes => 'authenticated', credential => 'session' );
bind( $d, id => 'rename', operation => 'core.set', modes => 'authenticated', callers => 'staff',
    apply => 'immediate', params => 'id=id,title=set.name', fixed => 'model=res.partner' );
bind( $d, id => 'rename_later', operation => 'core.set', modes => 'authenticated', callers => 'staff',
    params => 'id=id,title=set.name', fixed => 'model=res.partner' );

sub calls { my $r = Lazysite::Odoo::read_calls() || []; return $r }
sub last_call { return calls()->[0] }
sub run_b {
    my ( $id, $in, %ctx ) = @_;
    my ( undef, $r ) = quiet( sub {
            my ($b) = Lazysite::Odoo::find_binding($id);
            Lazysite::Odoo::call( $b, $in // {}, mode => 'public', ip => '192.0.2.7', %ctx );
    } );
    return $r;
}
sub partner_name {
    open my $fh, '<', "$state/state.json" or return undef;
    local $/;
    my $s = JSON::PP::decode_json(<$fh>);
    my $p = $s->{data}{'res.partner'}{1};
    return $p ? $p->{name} : undef;
}

my $svc = oomd_start( sub { Lazysite::Daemon::Service::Oomd::run( docroot => $d ) } );
ok( wait_until( sub { oomd_up($d) }, 30 ), 'the real oomd is up (started by the extension\'s service)' )
    or BAIL_OUT('oomd did not start: ' . Lazysite::Daemon::Service::Oomd::failure_reason($d));

subtest 'a read is answered by the daemon, not by this process' => sub {
    my $r = run_b( 'who', { e => 'hello' } );
    ok( $r->{ok}, 'the call is answered' ) or diag explain $r;
    is( $r->{report}{rows}[0]{echo}, 'hello', 'with the operation\'s report' );
    isnt( $r->{report}{rows}[0]{pid}, $$, 'by a process that is not this one' );
    is( Lazysite::Odoo::last_via(), 'daemon', 'the engine says daemon' );
    is( last_call()->{via}, 'daemon', 'and the call record keeps it' );
    is( last_call()->{outcome}, 'answered', 'as an answer' );
};

subtest 'SM1144\'s call phase says oomd' => sub {
    local @ENV{qw(DOCUMENT_ROOT)} = ($d);
    require "$root/lazysite-odoo.pl";
    Lazysite::Timing::begin();
    Lazysite::Timing::operator(1);
    main::_timed( sub { run_b( 'who', { e => 'x' } ) } );
    my $h = Lazysite::Timing::header_line();
    like( $h, qr/call;desc="oomd";dur=\d/, 'the Server-Timing call phase carries desc="oomd"' ) or diag $h;
};

subtest 'a write is planned and applied through the daemon, with the actor on the approval' => sub {
    my $r = run_b( 'rename', { id => 1, title => 'Renamed by the daemon' }, mode => 'authenticated', actor => 'alice', caps => { manage_connectors => 1 }, groups => ['staff'] );
    ok( $r->{ok} && $r->{applied}, 'applied immediately' ) or diag explain $r;
    is( partner_name(), 'Renamed by the daemon', 'the fake Odoo changed' );
    is( last_call()->{via}, 'daemon', 'via daemon on the write too' );
    my $txt = '';
    File::Find::find( { no_chdir => 1, wanted => sub { return unless -f $_ && /\.json\z/; open my $fh, '<', $_ or return; local $/; $txt .= <$fh> } }, "$d/lazysite/odoo/runs" );
    like( $txt, qr/binding:rename/, 'the approval records the actor lazysite sent (the binding, for apply: immediate)' );
};

subtest 'a plan waits for its maker\'s confirm, and the confirm goes through the daemon' => sub {
    my %who = ( mode => 'authenticated', actor => 'alice', caps => { manage_connectors => 1 }, groups => ['staff'], ip => '192.0.2.7' );
    my $r = run_b( 'rename_later', { id => 1, title => 'Confirmed later' }, %who );
    ok( $r->{ok} && $r->{planned}, 'planned' ) or diag explain $r;
    is( partner_name(), 'Renamed by the daemon', 'nothing written yet' );
    my ( undef, $c ) = quiet( sub { Lazysite::Odoo::confirm( $r->{plan}, %who ) } );
    ok( $c->{ok} && $c->{applied}, 'confirmed' ) or diag explain $c;
    is( partner_name(), 'Confirmed later', 'and applied by the daemon' );
    is( last_call()->{via}, 'daemon', 'the confirm\'s record says daemon' );
    is( last_call()->{phase}, 'apply', 'as the apply (the phase the in-process confirm records)' );
    my ( undef, $other ) = quiet( sub { Lazysite::Odoo::confirm( $r->{plan}, %who, actor => 'bob' ) } );
    ok( !$other->{ok}, 'somebody else cannot confirm it' );
};

subtest 'a person\'s session id goes with the request and is kept nowhere new' => sub {
    my $SID = 'SESSION-ID-' . join( '', map { ( 'a' .. 'f' )[ rand 6 ] } 1 .. 20 );
    my $r = run_b( 'mine', {}, mode => 'authenticated', odoo_session => $SID, actor => 'x' );
    ok( $r->{ok}, 'a session binding is answered through the daemon' ) or diag explain $r;
    is( last_call()->{via}, 'daemon', 'via daemon' );
    like( last_call()->{actor}, qr/\Asession:[0-9a-f]{16}\z/, 'the record names the person by a hash' );
    my @hits;
    File::Find::find( { no_chdir => 1, wanted => sub {
                return unless -f $_ && !-S $_;
                open my $fh, '<:raw', $_ or return;
                local $/;
                push @hits, $_ if index( <$fh>, $SID ) >= 0;
    } }, $d );
    is_deeply( \@hits, [], 'the session id is in no file under the site' );
};

oomd_stop($svc);
ok( !oomd_up($d), 'the daemon is stopped' );

subtest 'with the daemon down and odoo_daemon: on, the call falls back in-process and says so' => sub {
    my $r = run_b( 'who', { e => 'fallback' } );
    ok( $r->{ok}, 'the call is still answered' ) or diag explain $r;
    is( $r->{report}{rows}[0]{pid}, $$, 'by this process' );
    is( Lazysite::Odoo::last_via(), 'in-process', 'the engine says in-process' );
    is( last_call()->{via}, 'in-process', 'and the record records the fallback' );
    local @ENV{qw(DOCUMENT_ROOT)} = ($d);
    Lazysite::Timing::begin();
    Lazysite::Timing::operator(1);
    main::_timed( sub { run_b( 'who', { e => 'x' } ) } );
    like( Lazysite::Timing::header_line(), qr/call;desc="in-process";dur=/, 'the call phase says in-process' );
};

subtest 'odoo_daemon: required refuses a call when the daemon is down' => sub {
    write_conf( $d, odoo_url => 'https://odoo.example', odoo_db => 'local16', odoo_login => 'tester',
        odoo_allow_writes => 'true', odoo_packs => 'Odoo::Test::OomdOps', odoo_daemon => 'required' );
    my $r = run_b( 'who', { e => 'x' } );
    ok( !$r->{ok}, 'refused' ) or diag explain $r;
    is( $r->{kind}, 'daemon-down', 'with OOM\'s daemon-down code' );
    like( $r->{error}, qr/daemon is not running.*requires it/, 'and the extension says so' );
    is( last_call()->{outcome}, 'unanswered', 'recorded as unanswered' );
    ok( !defined last_call()->{via}, 'no path was taken' );
};

subtest 'with odoo_daemon off nothing goes near the daemon' => sub {
    write_conf( $d, odoo_url => 'https://odoo.example', odoo_db => 'local16', odoo_login => 'tester',
        odoo_allow_writes => 'true', odoo_packs => 'Odoo::Test::OomdOps' );
    my $r = run_b( 'who', { e => 'off' } );
    ok( $r->{ok}, 'answered' );
    is( $r->{report}{rows}[0]{pid}, $$, 'in-process' );
    is( last_call()->{via}, 'in-process', 'recorded as in-process' );
};

done_testing();
