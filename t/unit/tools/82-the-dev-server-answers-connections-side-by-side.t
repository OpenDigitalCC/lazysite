#!/usr/bin/perl
# SM1151 (P5/Q4): the dev server handles connections concurrently.
#
# The oom-lab found a page's parallel requests queuing behind one accept loop,
# so its timings measured the queue. A test processor that sleeps one second
# stands for the slow request: two of them must finish in about one second, not
# two; and with the cap at 2, four finish in about two (two waves) - neither
# one at a time (four) nor all at once (one).
use strict;
use warnings;
use Test::More;
use IO::Socket::INET;
use Time::HiRes qw(time sleep);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root site_tempdir);
use NginxHarness qw(free_port);

my $root   = repo_root();
my $server = "$root/tools/lazysite-server.pl";
my $docroot = site_tempdir();

# A processor that takes one second, then answers.
my $slow = "$docroot/../slow-processor.pl";
open my $sp, '>', $slow or die $!;
print {$sp} qq{#!/usr/bin/perl\nselect(undef,undef,undef,1.0);\nprint "Content-Type: text/plain\\r\\n\\r\\nslow\\n";\n};
close $sp;

my @pids;
END { kill 'TERM', $_ for @pids }

sub start_server {
    my ($cap) = @_;
    my $port = free_port();
    my $pid  = fork();
    die 'fork failed' unless defined $pid;
    if ( !$pid ) {
        open STDOUT, '>', '/dev/null';
        open STDERR, '>', '/dev/null';
        $ENV{LAZYSITE_DEV_MAX_CONN} = $cap;
        exec $^X, $server, '--docroot', $docroot, '--processor', $slow,
            '--no-seed', '--port', $port;
        exit 1;
    }
    push @pids, $pid;
    for ( 1 .. 80 ) {
        my $s = IO::Socket::INET->new( PeerAddr => '127.0.0.1', PeerPort => $port );
        if ($s) { close $s; last }
        sleep 0.1;
    }
    return ( $port, $pid );
}

# Open $n connections at once, send a request on each, and return the seconds
# until every answer is read plus how many said "slow".
sub burst {
    my ( $port, $n ) = @_;
    my $t0 = time;
    my @c;
    for ( 1 .. $n ) {
        my $s = IO::Socket::INET->new( PeerAddr => '127.0.0.1', PeerPort => $port ) or die $!;
        print {$s} "GET /slow HTTP/1.0\r\nHost: localhost\r\n\r\n";
        push @c, $s;
    }
    my $ok = 0;
    for my $s (@c) {
        local $/;
        my $r = <$s>;
        $ok++ if defined $r && $r =~ /slow/;
        close $s;
    }
    return ( time - $t0, $ok );
}

my ( $port, $pid ) = start_server(8);
my ( $secs, $ok ) = burst( $port, 2 );
is( $ok, 2, 'both requests were answered' );
cmp_ok( $secs, '<', 1.7, "two one-second requests finish side by side ($secs s, not two)" );

# Children do not accumulate: after the burst the server still answers.
( $secs, $ok ) = burst( $port, 1 );
is( $ok, 1, 'the server still answers after the children were reaped' );

kill 'TERM', $pid;
waitpid $pid, 0;

( $port, $pid ) = start_server(2);
( $secs, $ok ) = burst( $port, 4 );
is( $ok, 4, 'with the cap at 2, four requests are all answered' );
cmp_ok( $secs, '>=', 1.9, "and no more than two run at once ($secs s: two waves)" );
cmp_ok( $secs, '<', 3.5, 'but they are not queued one at a time' );

kill 'TERM', $pid;
waitpid $pid, 0;
done_testing;
