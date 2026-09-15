#!/usr/bin/perl
# fetch.pl URL - fetch a page from the local dev server.
#
# WHY THIS EXISTS RATHER THAN `curl`. The first cold run of setup.sh in a clean
# ubuntu:24.04 container failed at the render check, and the cause was not the
# engine: THE BASE IMAGE HAS NO curl. Every line of this skill that reached for
# it would have failed the same way, in a container the editor cannot inspect,
# reporting something that looks like a broken page.
#
# Perl is the one interpreter guaranteed to be here - the engine depends on it,
# so if perl is missing nothing else would have worked either - and
# IO::Socket::INET is core, so this adds no dependency at all. curl still works
# where it exists; nothing here requires it.
#
# Prints the body on stdout. Exit 0 on a 2xx, 1 otherwise, with the status line
# on stderr - so `fetch.pl URL >page.html` can be tested like any command.
use strict;
use warnings;
use IO::Socket::INET;

my $url = shift @ARGV;
unless ( defined $url && $url =~ m{^http://([^/:]+)(?::(\d+))?(/.*)?$} ) {
    print {*STDERR} "Usage: fetch.pl http://127.0.0.1:8080/path\n";
    exit 2;
}
my ( $host, $port, $path ) = ( $1, $2 || 80, $3 || '/' );

my $sock = IO::Socket::INET->new(
    PeerAddr => $host,
    PeerPort => $port,
    Proto    => 'tcp',
    Timeout  => 10,
);
unless ($sock) {
    print {*STDERR} "fetch: cannot connect to $host:$port - is the dev server running? ($!)\n";
    exit 1;
}

print {$sock} "GET $path HTTP/1.0\r\nHost: $host\r\n"
    . "User-Agent: lazysite-skill/1\r\nConnection: close\r\n\r\n";

my $raw = do { local $/; <$sock> };
close $sock;
$raw = '' unless defined $raw;

my ( $head, $body ) = split /\r?\n\r?\n/, $raw, 2;
$head //= '';
$body //= '';
my ($status) = ( $head =~ m{^HTTP/\S+\s+(\d{3})} );
$status //= 0;

print $body;
print {*STDERR} "fetch: $status $url\n";
exit( $status >= 200 && $status < 300 ? 0 : 1 );
