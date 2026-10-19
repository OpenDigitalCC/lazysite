#!/usr/bin/perl
# SM1180: A CALL THAT oomd ANSWERS LOADS NO OOM IN THE ENDPOINT.
#
# Inbox 2026-10-19-what-lazysite-adds-to-an-odoo-call.md: "lazysite and OOM must
# add minimal latency to Odoo ... a fresh perl loading OOM 250 ms vs the oomd light
# client 61 ms". SM1164 sent the call to oomd but the endpoint still read OOM's
# registry in-process first, for the binding's operation declaration. The ruling:
# store each binding's declaration at save, stamped with the OOM version, so the
# endpoint calls oomd without loading OOM.
#
# THE TELL is %INC in a fresh process: every call here runs in a child perl (a CGI
# is a fresh process too), against the REAL vendored oomd under the real supervisor
# (as t/unit/odoo/61 does), and the child reports which OOM modules it loaded.
use strict;
use warnings;
use Test::More;
use JSON::PP ();
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper qw(repo_root);
use OdooTest   qw(oom_or_skip bind quiet write_conf);

BEGIN { oom_or_skip() }
use OdooDaemonTest qw(oomd_site oomd_env oomd_start oomd_stop oomd_up wait_until);
use Lazysite::Odoo ();
use Lazysite::Daemon::Service::Oomd ();

my $root  = repo_root();
my $state = oomd_env();
$ENV{PERL5LIB} .= ':' . $root . '/t/lib';    # the daemon loads the rows test pack too (SM1198)
my $d     = oomd_site( odoo_packs => 'Odoo::Test::OomdOps,LazysiteTest::OdooOps' );
$Lazysite::Odoo::DOCROOT = $d;

bind( $d, id => 'who', operation => 'oomd.pid', modes => 'public', params => 'e=echo' );
bind( $d, id => 'later', operation => 'core.set', modes => 'authenticated', callers => 'staff',
    params => 'id=id,title=set.name', fixed => 'model=res.partner' );

# SM1198: a binding with a declared list of rows (shop.order, capped at 3 by the operation).
bind( $d, id => 'order', operation => 'shop.order', modes => 'authenticated', callers => 'staff',
    params => 'lines=lines', fixed => 'basket_key=cart' );

my $decl_file = "$d/lazysite/odoo/decl/who.json";
sub read_decl { open my $fh, '<', $decl_file or return undef; local $/; return JSON::PP::decode_json(<$fh>) }
sub write_decl { my ($x) = @_; open my $fh, '>', $decl_file or die $!; print {$fh} JSON::PP->new->canonical->encode($x); close $fh }

# The child: one call, in a fresh perl, and what it loaded.
my $script = "$d/child-call.pl";
{
    open my $fh, '>', $script or die $!;
    print {$fh} <<'PERL';
use strict; use warnings; no warnings 'once';
use lib $ENV{T_REPO} . '/lib';
use JSON::PP;
require Lazysite::Odoo;
$Lazysite::Odoo::DOCROOT = $ENV{T_DOCROOT};
if ( $ENV{T_FAKE} ) { unshift @INC, $ENV{T_TESTLIB}; require OdooTest; $Lazysite::Odoo::TRANSPORT = OdooTest::fake_shop() }
my ($b) = Lazysite::Odoo::find_binding( $ENV{T_BINDING} );
my $in  = $ENV{T_INPUT} ? decode_json( $ENV{T_INPUT} ) : { e => 'hi' };
my @ctx = $ENV{T_INPUT} ? ( mode => 'authenticated', actor => 'sam', groups => ['staff'], caps => {}, ip => '192.0.2.7' ) : ( mode => 'public', ip => '192.0.2.7' );
my $r = Lazysite::Odoo::call( $b, $in, @ctx );
my @loaded = sort grep { m{\AOdoo/} } keys %INC;
print encode_json( { ok => $r->{ok} ? 1 : 0, planned => $r->{planned} ? 1 : 0, kind => $r->{kind}, error => $r->{error},
    pid => $r->{report}{rows}[0]{pid}, via => Lazysite::Odoo::last_via(),
    loaded => { map { $_ => 1 } @loaded } } ), "\n";
PERL
    close $fh;
}
sub child {
    my (%o) = @_;
    local $ENV{T_REPO}    = $root;
    local $ENV{T_DOCROOT} = $d;
    local $ENV{T_BINDING} = $o{binding} // 'who';
    local $ENV{T_FAKE}    = $o{fake} ? 1 : 0;
    local $ENV{T_INPUT}   = $o{input} ? JSON::PP::encode_json( $o{input} ) : '';
    local $ENV{T_TESTLIB} = "$root/t/lib";
    open my $ph, '-|', $^X, $script or die $!;
    my $out = do { local $/; <$ph> };
    close $ph;
    my $r = eval { JSON::PP::decode_json($out) } or do { diag "child said: $out"; return {} };
    return $r;
}
sub last_call { my $r = Lazysite::Odoo::read_calls() || []; return $r->[0] }
my @FORBIDDEN = qw(Odoo/Ops/Registry.pm Odoo/Ops/Service.pm Odoo/Client.pm);
sub loads_oom { my ($r) = @_; return grep { $r->{loaded}{$_} } @FORBIDDEN }

subtest 'saving a binding stores its operation declaration, stamped' => sub {
    my $x = read_decl();
    ok( $x, 'lazysite/odoo/decl/who.json exists' ) or return;
    require Odoo::Ops::Version;
    is( $x->{stamp}{oom}, $Odoo::Ops::Version::VERSION, 'stamped with the installed OOM version' );
    is_deeply( $x->{stamp}{packs}, ['Odoo::Test::OomdOps', 'LazysiteTest::OdooOps'], 'and the site\'s packs' );
    is( $x->{operation}, 'oomd.pid', 'naming the operation' );
    ok( exists $x->{params}{echo}, 'with its parameter declarations' ) or diag explain $x->{params};
    is( $x->{writes}, 0, 'and whether it writes' );
    like( $decl_file, qr{/lazysite/odoo/decl/}, 'in the Odoo store, outside the docroot\'s pages' );
    ok( read_decl_for('later') && read_decl_for('later')->{writes}, 'a writing operation is stored as writing' );
};
sub read_decl_for { my ($id) = @_; open my $fh, '<', "$d/lazysite/odoo/decl/$id.json" or return undef; local $/; return JSON::PP::decode_json(<$fh>) }

my $svc = oomd_start( sub { Lazysite::Daemon::Service::Oomd::run( docroot => $d ) } );
ok( wait_until( sub { oomd_up($d) }, 30 ), 'the real oomd is up' )
    or BAIL_OUT( 'oomd did not start: ' . Lazysite::Daemon::Service::Oomd::failure_reason($d) );

subtest 'a daemon-path call loads no registry, no service, no OOM client' => sub {
    my $r = child();
    ok( $r->{ok}, 'the call is answered' ) or diag explain $r;
    is( $r->{via}, 'daemon', 'by the daemon' );
    isnt( $r->{pid}, $$, 'a process that is not this one' );
    my @bad = loads_oom($r);
    is_deeply( \@bad, [], 'none of Registry, Service, Odoo::Client is in %INC' ) or diag join ', ', sort keys %{ $r->{loaded} };
    note 'Odoo modules loaded: ' . join( ', ', sort keys %{ $r->{loaded} } );
    is( last_call()->{decl}, 'stored', 'the call record says the stored declaration was used' );
    is( last_call()->{via},  'daemon', 'and the path' );
};

# SM1198: a request that feeds a rows parameter used to load OOM's tree, because
# Odoo::Ops::Operation->check_rows lives with the registry (SM1180 recorded it as
# the one thing the stored declaration could not answer). OOM 0.36 ships
# Odoo::Ops::Rows->check, with the same rules and errors, loading only Odoo::Error,
# Odoo::JSON and Odoo::Ops; the binding's rows check calls that.
subtest 'a call with a list of rows loads no registry, no service, no OOM client' => sub {
    my $row = sub { { product_id => 1, qty => 2 } };
    my $r = child( binding => 'order', input => { lines => [ $row->(), $row->() ] } );
    ok( $r->{planned}, 'the call is answered (a plan)' ) or diag explain $r;
    is( $r->{via}, 'daemon', 'by the daemon' );
    my @bad = loads_oom($r);
    is_deeply( \@bad, [], 'none of Registry, Service, Odoo::Client is in %INC' ) or diag join ', ', sort keys %{ $r->{loaded} };
    note 'Odoo modules loaded: ' . join( ', ', sort keys %{ $r->{loaded} } );
    is( last_call()->{decl}, 'stored', 'on the stored declaration' );

    # The check still runs, and still names the row: the light class applies the same rules.
    my $bad = child( binding => 'order', input => { lines => [ $row->(), { product_id => 'x', qty => 2 } ] } );
    ok( !$bad->{ok} && !$bad->{planned}, 'a bad row is refused' ) or diag explain $bad;
    like( $bad->{error} // '', qr/row 2|product_id/, 'naming the row or key' );
    is_deeply( [ loads_oom($bad) ], [], 'and the refusal loads no OOM either' );
    my $many = child( binding => 'order', input => { lines => [ ( $row->() ) x 4 ] } );
    like( $many->{error} // '', qr/4 rows; at most 3/, 'a list over the operation\'s max is refused with its count' );
};

subtest 'a stale stamp is re-checked once, stored again, and said' => sub {
    my $x = read_decl();
    $x->{stamp}{oom} = '0.01';
    write_decl($x);
    my $r = child();
    ok( $r->{ok}, 'the call is still answered' ) or diag explain $r;
    is( last_call()->{decl}, 'rechecked', 'the record says it was re-checked' );
    is( $r->{via}, 'daemon', 'and still goes to the daemon' );
    ok( $r->{loaded}{'Odoo/Ops/Registry.pm'}, 'the registry was read in-process, once' );
    require Odoo::Ops::Version;
    is( read_decl()->{stamp}{oom}, $Odoo::Ops::Version::VERSION, 'and the declaration is stamped again' );
    my $r2 = child();
    is( last_call()->{decl}, 'stored', 'so the next call uses it' );
    is_deeply( [ loads_oom($r2) ], [], 'and loads no OOM' );
};

subtest 'a changed pack list is a stale stamp' => sub {
    my $x = read_decl();
    $x->{stamp}{packs} = ['Some::Other::Pack'];
    write_decl($x);
    child();
    is( last_call()->{decl}, 'rechecked', 're-checked' );
    is_deeply( read_decl()->{stamp}{packs}, ['Odoo::Test::OomdOps', 'LazysiteTest::OdooOps'], 'and stamped with the site\'s packs again' );
};

subtest 'no stored declaration (a binding saved before this release) is re-checked once' => sub {
    unlink $decl_file;
    my $r = child();
    ok( $r->{ok}, 'answered' );
    is( last_call()->{decl}, 'rechecked', 'the record says re-checked' );
    ok( read_decl(), 'and the declaration is stored' );
    child();
    is( last_call()->{decl}, 'stored', 'the next call uses it' );
};

subtest 'a declaration that changed with OOM is honoured' => sub {
    # Simulate OOM changing the operation's parameters: the stored copy is of the
    # OLD OOM (a different parameter set), so with a matching stamp it is what the
    # request path believes - the binding no longer fits it and is refused ...
    my $good = read_decl();
    my $x    = read_decl();
    $x->{params} = { other => { type => 'str' } };
    write_decl($x);
    my $r = child();
    ok( !$r->{ok}, 'a stamp that matches is trusted: the binding does not fit the stored declaration' );
    like( $r->{error}, qr/does not fit its operation/, 'and the refusal says so' ) or diag explain $r;
    # ... and after the OOM version changes (the stamp no longer matches) the new
    # declaration is read, and the call goes through.
    $x->{stamp}{oom} = '0.01';
    write_decl($x);
    $r = child();
    ok( $r->{ok}, 'with the stamp stale the real declaration is read and the call is answered' ) or diag explain $r;
    is_deeply( read_decl()->{params}, $good->{params}, 'and the stored declaration is the operation\'s own again' );
};

oomd_stop($svc);
ok( !oomd_up($d), 'the daemon is stopped' );

subtest 'with the daemon down and odoo_daemon: on, the fallback loads OOM and says in-process' => sub {
    my $r = child( fake => 1 );
    ok( $r->{ok}, 'the call is still answered' ) or diag explain $r;
    is( $r->{via}, 'in-process', 'in-process' );
    is( last_call()->{decl}, 'stored', 'on the stored declaration' );
    ok( $r->{loaded}{'Odoo/Ops/Registry.pm'}, 'OOM is loaded now, for the fallback' );
};

subtest 'odoo_daemon off is unchanged: in-process, the registry read, no stored declaration used' => sub {
    write_conf( $d, odoo_url => 'https://odoo.example', odoo_db => 'local16', odoo_login => 'tester',
        odoo_allow_writes => 'true', odoo_packs => 'Odoo::Test::OomdOps' );
    my $r = child( fake => 1 );
    ok( $r->{ok}, 'answered' ) or diag explain $r;
    is( $r->{via}, 'in-process', 'in-process' );
    ok( $r->{loaded}{'Odoo/Ops/Registry.pm'}, 'the registry was read' );
    note scalar( keys %{ $r->{loaded} } ) . ' Odoo modules loaded in-process';
    ok( !defined last_call()->{decl}, 'and the record carries no decl' );
};

done_testing();
