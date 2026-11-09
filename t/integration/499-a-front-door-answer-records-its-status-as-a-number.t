#!/usr/bin/perl
# n795 (the 0.16.9 restack): AN ANSWER THE POOL'S FRONT DOOR GIVES ITSELF RECORDS
# ITS STATUS AS A NUMBER.
#
# _front_fail answers what the front door cannot relay (a surface that is not
# there, a body over the cap, a failed fork or pipe, a relay that timed out, a
# blocked probe). It stored its whole status line - "500 Internal Server Error" -
# as the access record's status, and the record writes the status as a number, so
# every such answer put an "isn't numeric" warning in the worker's log. SM297's
# 503 had worked around it by setting the number after the call. Now _front_fail
# stores the code, for every caller.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use POSIX      qw(dup2 strftime);
use Socket     qw(AF_UNIX SOCK_STREAM sockaddr_un);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root env_passthrough site_tempdir);

plan skip_all => 'FCGI.pm not installed (the plain-CGI path has no front door)'
    unless eval { require FCGI; 1 };
require MiniFcgi;

my $root = repo_root();
my $d    = site_tempdir();
( my $base = $d ) =~ s{/[^/]+\z}{};
my $LZ = "$d/lazysite";

sub spit {
    my ( $p, $t ) = @_;
    make_path( $p =~ s{/[^/]+\z}{}r );
    open my $fh, '>', $p or die "$p: $!";
    print {$fh} $t;
    close $fh;
    return;
}
sub slurp { open my $fh, '<', $_[0] or return ''; local $/; return scalar <$fh> // '' }

spit( "$LZ/lazysite.conf", "site_name: T\n" );
spit( "$d/index.md",       "---\ntitle: Home\n---\nHOME BODY\n" );

# A cgi-bin holding the processor alone: every other surface is "not there".
my $cgibin = "$base/cgi-bin";
make_path($cgibin);
symlink "$root/lazysite-processor.pl", "$cgibin/lazysite-processor.pl" or die "symlink: $!";

my $sock = "$base/pool.sock";
my $LOG  = "$base/worker-stderr.log";
socket( my $lsock, AF_UNIX, SOCK_STREAM, 0 ) or die "socket: $!";
bind( $lsock, sockaddr_un($sock) )           or die "bind: $!";
listen( $lsock, 5 )                          or die "listen: $!";
my $pid = fork() // die "fork: $!";
if ( $pid == 0 ) {
    %ENV = ( env_passthrough(), DOCUMENT_ROOT => $d, LAZYSITE_FCGI_MAX_REQUESTS => 500,
        LAZYSITE_FRONT_DOOR => 1, LAZYSITE_CGIBIN => $cgibin, LAZYSITE_LOG_LEVEL => 'WARN' );
    dup2( fileno($lsock), 0 ) or die "dup2: $!";
    open STDERR, '>', $LOG or die $!;
    exec $^X, "$root/lazysite-processor.pl";
    die "exec: $!";
}
close $lsock;

sub request {
    my ($uri) = @_;
    my $r = MiniFcgi::fcgi_request( $sock,
        {   REQUEST_METHOD => 'GET', REMOTE_ADDR => '198.51.100.1', HTTP_HOST => 'site.test',
            DOCUMENT_ROOT  => $d, REDIRECT_URL => $uri, REQUEST_URI => $uri, QUERY_STRING => '',
            SCRIPT_NAME    => $uri } );
    return wantarray ? ( $r->{stdout} // '', $r->{stderr} // '' ) : $r->{stdout} // '';
}

my $up;
for ( 1 .. 50 ) {
    $up = eval { request('/') };
    last if $up && $up =~ /HOME BODY/;
    select( undef, undef, undef, 0.1 );
}
like( $up // '', qr/HOME BODY/, 'the one-worker pool is up with the front door on' )
    or BAIL_OUT( slurp($LOG) );

my $log0 = length slurp($LOG);
my ( $out, $err ) = request('/cgi-bin/lazysite-mcp.pl');
like( $out, qr/\AStatus: 500 /, 'a surface the cgi-bin lacks is answered at the door (500)' )
    or diag($out);
like( $out, qr/surface not found/, '...by _front_fail' );
# The request's stderr is its FastCGI stream; the worker's own is $LOG.
my $log = $err . substr slurp($LOG), $log0;
unlike( $log, qr/isn't numeric/, 'no non-numeric warning in the worker\'s log' ) or diag($log);

my $ymd = strftime( '%Y%m%d', gmtime );
my ($rec) = grep { /"p":"\/cgi-bin\/lazysite-mcp\.pl"/ } split /\n/, slurp("$LZ/logs/access-$ymd.jsonl");
ok( defined $rec, 'the answer is in the access record' );
like( $rec // '', qr/"s":500[,}]/, 'with its status as the number 500' );
like( $rec // '', qr/"ch":"front"/, 'on the front channel' );

kill 'TERM', $pid;
waitpid $pid, 0;
done_testing();
