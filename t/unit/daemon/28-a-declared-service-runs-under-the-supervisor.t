#!/usr/bin/perl
# SM1369 X5, H-5 (ruling 55): A SERVICE AN EXTENSION DECLARES RUNS UNDER THE
# SUPERVISOR, BEHIND ITS OWN GATE, AND THE SUPERVISOR NAMES NO EXTENSION.
#
# `hooks.services` - { name, wanted, run, reason } - is read from the hook index
# by Lazysite::Daemon::Supervisor; each function is the extension's own, reached
# through Lazysite::Extensions::Hooks::call_hook. A fixture extension declares
# one, and through a real index and the real supervisor (forked):
#
#   * services() lists it only when asked for, and the scheduler always;
#   * its gate is its `wanted`: true starts it (its `run`, in a child of its own,
#     given the docroot), false stops it, and one that dies is not wanted;
#   * Status lists it, with its own `reason` once the supervisor gives up;
#   * the extension switched off in lazysite.conf stops it (G-1), whatever the
#     index says;
#   * a service may not take the scheduler's name, and a name has one owner.
#
# Sabotage: make _declared_services return nothing and the service is never
# listed or started - this fails.
use strict;
use warnings;
use Test::More;
use File::Path     qw(make_path);
use File::Basename qw(dirname);
use JSON::PP       ();
use POSIX          ();
use Time::HiRes    ();
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper qw(site_tempdir index_extensions);
use Lazysite::Daemon::Supervisor ();
use Lazysite::Extensions::Hooks  ();

$ENV{LAZYSITE_LOG_LEVEL} = 'ERROR';
no warnings 'once';
$Lazysite::Daemon::Supervisor::SERVICE_GATE_EVERY = 1;
$Lazysite::Daemon::Supervisor::GATE_EVERY         = 1;

sub spit { my ( $p, $c ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $c; close $fh; return }

sub write_extension {
    my ( $path, $desc ) = @_;
    my $json = JSON::PP->new->canonical->encode($desc);
    $json =~ s/'/'\\''/g;
    spit( $path, "#!/usr/bin/perl\nprint q'$json' if \@ARGV && \$ARGV[0] eq '--describe';\nexit 0;\n" );
    chmod 0755, $path or die $!;
    return;
}

my $d    = site_tempdir();
my $base = dirname($d);
make_path( "$d/lazysite", "$base/extensions/probe/lib" );
spit( "$d/lazysite/daemon.conf", "daemon_restart_backoff: 1\n" );

sub set_extensions {
    my (@x) = @_;
    spit( "$d/lazysite/lazysite.conf.tmp", "site_name: t\nextensions:\n" . join( '', map {"  - extensions/$_.pl\n"} @x ) );
    rename "$d/lazysite/lazysite.conf.tmp", "$d/lazysite/lazysite.conf" or die $!;
    return;
}
# The daemon extension's descriptor, as the registry needs it to be listed.
write_extension( "$base/extensions/daemon.pl", { id => 'daemon', name => 'Daemon', contract => 1, owns => {} } );
write_extension( "$base/extensions/probe.pl", {
        id => 'probe', name => 'Probe', contract => 1,
        owns => { hooks => { services => [ {
                        name => 'probe-svc', wanted => 'ProbeSvc::wanted', run => 'ProbeSvc::run',
                        reason => 'ProbeSvc::reason' } ] } } } );
spit( "$base/extensions/probe/lib/ProbeSvc.pm", <<'PM' );
package ProbeSvc;
sub wanted { my ($root) = @_; die "asked to die\n" if -e "$root/../probe-dies"; return -e "$root/../probe-wanted" ? 1 : 0 }
sub run {
    my (%a) = @_;
    my $stop = 0;
    local $SIG{TERM} = sub { $stop = 1 };
    open my $fh, '>', "$a{docroot}/../probe-ran" or return 3;
    print {$fh} "$$\n";
    close $fh;
    select( undef, undef, undef, 0.1 ) until $stop;
    return 0;
}
sub reason { return 'the probe says why' }
1;
PM

set_extensions(qw(daemon probe));
my $r = index_extensions($d);
ok( $r->{ok} && grep( { $_ eq 'probe' } @{ $r->{indexed} } ), 'the fixture\'s service is indexed' ) or diag explain $r;

sub wait_until {
    my ( $code, $secs ) = @_;
    my $until = Time::HiRes::time() + $secs;
    while ( Time::HiRes::time() < $until ) { return 1 if $code->(); Time::HiRes::sleep(0.1) }
    return 0;
}

subtest 'the registry reads the declaration' => sub {
    is_deeply( [ map { $_->{name} } Lazysite::Daemon::Supervisor::services($d) ], ['scheduler'],
        'only the scheduler unless the service is asked for' );
    is_deeply( [ map { $_->{name} } Lazysite::Daemon::Supervisor::services( $d, 'probe-svc' => 1 ) ],
        [ 'scheduler', 'probe-svc' ], 'and the declared service after it when it is' );
    ok( !Lazysite::Daemon::Supervisor::_wanted( $d, 'probe-svc' ), 'its gate is shut: not wanted' );
    spit( "$base/probe-wanted", "1\n" );
    ok( Lazysite::Daemon::Supervisor::_wanted( $d, 'probe-svc' ), 'its gate open: wanted' );
    spit( "$base/probe-dies", "1\n" );
    ok( !Lazysite::Daemon::Supervisor::_wanted( $d, 'probe-svc' ), 'a gate that dies: not wanted' );
    unlink "$base/probe-dies";
    ok( !Lazysite::Daemon::Supervisor::_wanted( $d, 'nothing-declared' ), 'a name nobody declares: not wanted' );
    is( Lazysite::Daemon::Supervisor::_service_reason( $d, 'probe-svc' ), '; probe-svc said: the probe says why',
        'its reason is its own words' );
};

subtest 'the supervisor runs it behind its gate, and off means off' => sub {
    my $pid = fork() // die "fork: $!";
    if ( !$pid ) {
        open STDERR, '>', "$base/supervisor.log";
        POSIX::_exit( Lazysite::Daemon::Supervisor::run( docroot => $d ) // 1 );
    }
    ok( wait_until( sub { -s "$base/probe-ran" }, 20 ), 'the service ran, in a child of its own' );
    my $svc_pid = do { open my $fh, '<', "$base/probe-ran"; my $p = <$fh> // ''; chomp $p; $p };
    ok( $svc_pid && kill( 0, $svc_pid ), 'and is running' );
    is( Lazysite::Daemon::Supervisor::service_pid( $d, 'probe-svc' ), $svc_pid, 'under its declared name' );
    my ($st) = grep { $_->{unit} eq 'probe-svc' } @{ Lazysite::Daemon::Supervisor::status($d)->{services} || [] };
    is( $st && $st->{verdict}, 'on', 'Status lists it, on' );

    unlink "$base/probe-wanted";
    ok( wait_until( sub { !kill( 0, $svc_pid ) }, 20 ), 'its gate shut: it is stopped' );

    spit( "$base/probe-wanted", "1\n" );
    unlink "$base/probe-ran";
    ok( wait_until( sub { -s "$base/probe-ran" }, 20 ), 'its gate open again: started again' );
    $svc_pid = do { open my $fh, '<', "$base/probe-ran"; my $p = <$fh> // ''; chomp $p; $p };

    set_extensions(qw(daemon));    # the index still names it; the conf does not
    ok( wait_until( sub { !kill( 0, $svc_pid ) }, 20 ), 'the extension switched off: it is stopped (G-1)' );

    kill 'TERM', $pid;
    waitpid $pid, 0;
    ok( !kill( 0, $svc_pid ), 'nothing is left running' );
};

subtest 'a service name is its declaration\'s own' => sub {
    my @bad = map { $_->{error} } Lazysite::Extensions::Hooks::validate_hooks( 'probe',
        { services => [ { name => 'scheduler', wanted => 'A::b', run => 'A::c' } ] } );
    ok( ( grep {/the engine's own service/} @bad ), 'the scheduler\'s name is refused' ) or diag explain \@bad;
    @bad = map { $_->{error} } Lazysite::Extensions::Hooks::validate_hooks( 'probe', { services => [ { name => 'x', run => 'A::c' } ] } );
    ok( ( grep {/must carry 'wanted'/} @bad ), 'a service with no gate is refused' ) or diag explain \@bad;
    my %clash = Lazysite::Extensions::Hooks::cross_problems( {
            alpha => { hooks => { services => [ { name => 'svc' } ] } },
            beta  => { hooks => { services => [ { name => 'svc' } ] } } } );
    like( ( $clash{beta} || [] )->[0] // '', qr/the service 'svc' is already declared by the extension 'alpha'/,
        'two extensions cannot both name one service' );
    ok( !$clash{alpha}, 'the first keeps it' );
};

done_testing;
