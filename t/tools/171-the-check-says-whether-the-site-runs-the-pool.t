#!/usr/bin/perl
# SM1144 (SM1082 R5): `lazysite check` reports whether this site runs the pool,
# and with how many workers, in one line a deploy report can read.
#
# SM1082's persistent-runtime work pays only on pooled sites, and the release
# manager is to rule per site (R5) once the fleet's pool status is known. Until
# now that status was found by looking at each host. The line is "pool: ..." in
# three shapes - no pool, a pool with N workers and its socket there, a pool
# configured whose socket is not - and a pool conf for another docroot is not
# this site's.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use IO::Socket::UNIX;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root run_cmd site_tempdir);

my $root   = repo_root();
my $script = "$root/tools/lazysite-check.pl";

my $doc = site_tempdir();
make_path("$doc/lazysite/auth");
open my $cf, '>', "$doc/lazysite/lazysite.conf" or die $!;
print {$cf} "site_name: T\n";
close $cf;

my $pools = tempdir( CLEANUP => 1 );
my $run   = tempdir( CLEANUP => 1 );

sub check {
    local $ENV{LAZYSITE_POOLS_DIR} = $pools;
    return run_cmd( $^X, $script, '--docroot', $doc );
}

sub conf {
    my ( $name, %kv ) = @_;
    open my $fh, '>', "$pools/$name.conf" or die $!;
    print {$fh} map { "$_=$kv{$_}\n" } sort keys %kv;
    close $fh;
}

# --- no pool conf for this site ----------------------------------------------------
like( check(), qr/pool: no \(plain CGI\)/, 'a site with no pool conf is reported as plain CGI' );

# --- a conf that names another docroot is not this site's ----------------------------
my $other = site_tempdir();
conf( 'other.example', DOCROOT => $other, WORKERS => 4 );
like( check(), qr/pool: no \(plain CGI\)/, 'a pool for another docroot does not make this one pooled' );

# --- a pool whose socket is not there -----------------------------------------------
my $sock = "$run/mine.example.sock";
conf( 'mine.example', DOCROOT => $doc, WORKERS => 3, SOCKET => $sock );
my $out = check();
like( $out, qr/pool: configured, 3 workers \(mine\.example\.conf\), but its socket \Q$sock\E is not there/,
    'a conf whose socket is absent is a pool that is not running' );
like( $out, qr/systemctl start lazysite\@mine\.example/, '...and the hint names the unit to start' );

# --- a running pool --------------------------------------------------------------------
my $srv = IO::Socket::UNIX->new( Local => $sock, Listen => 1 ) or die "socket: $!";
like( check(), qr/pool: yes, 3 workers \(mine\.example\.conf\)/, 'a pool with its socket up is reported with its workers' );

# --- the launcher's default is two workers --------------------------------------------
conf( 'mine.example', DOCROOT => $doc, SOCKET => $sock );
like( check(), qr/pool: yes, 2 workers/, 'WORKERS= unset reads as the launcher\'s default of 2' );
conf( 'mine.example', DOCROOT => $doc, SOCKET => $sock, WORKERS => 1 );
like( check(), qr/pool: yes, 1 worker \(/, 'and one worker is not pluralised' );

close $srv;
unlink $sock;
done_testing;
