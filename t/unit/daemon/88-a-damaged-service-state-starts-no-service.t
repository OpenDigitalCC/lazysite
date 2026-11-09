#!/usr/bin/perl
# Ruling 206 (item 17 of the 0.16.9 fault survey): A SERVICE STATE FILE THAT
# CANNOT BE TOLD STARTS NO SERVICE.
#
# The supervisor read a damaged lazysite/daemon/<name>.state.json as {} - no
# recorded start time - so it could not recognise an orphan of its own (SM755's
# proof is the pid AND that start time) and started a second copy beside it,
# the duplicate the supervisor lock exists to prevent. Now the supervisor
# refuses to start any service (exit 4), the log names the file and the remedy,
# the file is left as found, and Status says `failed` with the same remedy. An
# absent state file is a service never started, and starts as before.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use FindBin;
use POSIX ();
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use Lazysite::Daemon::Supervisor ();

sub spit  { my ( $p, $t ) = @_; open my $fh, '>:raw', $p or die "$p: $!"; print {$fh} $t; close $fh; return }
sub slurp { open my $fh, '<:raw', $_[0] or return ''; local $/; my $s = <$fh>; close $fh; return $s }

sub site {
    my $t = tempdir( CLEANUP => 1 );
    my $d = "$t/public_html";
    mkdir $d;
    mkdir "$d/lazysite";
    mkdir "$d/lazysite/daemon";
    spit( "$d/lazysite/lazysite.conf", "site_name: t\nextensions:\n  - extensions/daemon.pl\n" );
    spit( "$d/lazysite/daemon.conf",   "daemon_restart_backoff: 1\ndaemon_tick_seconds: 60\n" );
    return ( $t, $d );
}

my $LIVES = {
    name  => 'lives',
    start => sub {
        my $go = 1;
        local $SIG{TERM} = sub { $go = 0 };
        while ($go) { sleep 1 }
        return 0;
    },
};

sub start_supervisor {
    my ( $t, $d ) = @_;
    my $log = "$t/supervisor.log";
    my $pid = fork();
    die "fork: $!" unless defined $pid;
    if ( $pid == 0 ) {
        no warnings 'redefine';
        *Lazysite::Daemon::Supervisor::services = sub { return ($LIVES) };
        open STDERR, '>', $log or die $!;
        exit Lazysite::Daemon::Supervisor::run( docroot => $d );
    }
    return ( $pid, $log );
}

sub wait_exit {
    my ($pid) = @_;
    for ( 1 .. 50 ) {
        return $? >> 8 if waitpid( $pid, POSIX::WNOHANG() ) > 0;
        select( undef, undef, undef, 0.2 );
    }
    kill 'KILL', $pid;
    waitpid $pid, 0;
    return undef;
}

subtest 'absent state: the service starts' => sub {
    my ( $t, $d ) = site();
    my ($p) = start_supervisor( $t, $d );
    my $child;
    for ( 1 .. 25 ) {
        $child = slurp("$d/lazysite/daemon/lives.pid");
        last if length $child;
        select( undef, undef, undef, 0.2 );
    }
    chomp $child;
    ok( $child && kill( 0, $child ), 'the service is running' );
    kill 'TERM', $p;
    waitpid $p, 0;
};

subtest 'a state file that does not decode: nothing starts, and it is left as found' => sub {
    my ( $t, $d ) = site();
    my $state = "$d/lazysite/daemon/lives.state.json";
    spit( $state, '{"fails":0,"start_ticks":' );
    my ( $p, $log ) = start_supervisor( $t, $d );
    my $rc = wait_exit($p);
    is( $rc, 4, 'the supervisor refuses with exit 4' );
    ok( !-e "$d/lazysite/daemon/lives.pid", 'and started no service' );
    is( slurp($state), '{"fails":0,"start_ticks":', 'the state file is byte-identical' );
    like( slurp($log), qr/cannot tell - lazysite\/daemon\/lives\.state\.json cannot be read or does not decode/,
        'the log names the file' );
    like( slurp($log), qr/repair=lazysite check --docroot <docroot> names it/, 'and the remedy' );

    my $st = do {
        no warnings 'redefine';
        local *Lazysite::Daemon::Supervisor::services = sub { return ($LIVES) };
        Lazysite::Daemon::Supervisor::status($d);
    };
    my ($svc) = grep { ( $_->{unit} // '' ) eq 'lives' } @{ $st->{services} || [] };
    is( $svc->{verdict}, 'failed', 'Status says failed, not on and not starting' )
        or diag explain $st->{services};
    like( $svc->{message} // '', qr/lives\.state\.json cannot be read or does not decode/, 'naming the file' );
    like( $svc->{remedy}  // '', qr/lazysite check --docroot <docroot>/, 'with the remedy' );
};

done_testing();
