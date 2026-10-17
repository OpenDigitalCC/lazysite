#!/usr/bin/perl
# SM1127 (X12): a PUT whose body is shorter than its Content-Length, through a
# REAL Apache to lazysite-dav.pl.
#
# The 0.15.9 walk, X12: "The engine cannot be reached with a short body from
# outside: the front nginx deals with it first. [...] This needs a request that
# reaches Apache directly (on the host, or a test in the suite)." SM1114's
# t/unit/dav/33 drives the CGI with a closed stdin. This drives the layer the
# live front's Apache adds: a raw socket sends Content-Length 1000 and 100
# bytes, then either half-closes (the client is gone) or stalls (the client is
# stuck and Apache's Timeout ends it), and what Apache hands the CGI, and what
# it does to the CGI when it gives up, is whatever it is - the assertion is
# that nothing is stored, no name.tmp.<pid> is left, PROPFIND lists neither,
# and a response that does come back is the engine's 400, not Apache's.
use strict;
use warnings;
use Test::More;
use Time::HiRes qw(sleep time);
use IO::Socket::INET;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root site_tempdir setup_dav_site);

my $APACHE = -x '/usr/sbin/apache2' ? '/usr/sbin/apache2' : '';
plan skip_all => 'apache2 not installed' unless $APACHE;
my $MODS = '/usr/lib/apache2/modules';
plan skip_all => 'apache2 modules not found'
    unless -f "$MODS/mod_cgi.so" && -f "$MODS/mod_alias.so";

my $root = repo_root();
my $s    = setup_dav_site();
my $docroot = $s->{docroot};
# Apache's own files live in a site_tempdir tree (lint 118); the docroot is the
# DAV fixture's.
( my $site = site_tempdir() ) =~ s{/[^/]+\z}{};
my $cgibin = "$site/cgi-bin";
require File::Path;
File::Path::make_path( $cgibin, "$site/logs" );

sub spit {
    my ( $p, $t ) = @_;
    open my $fh, '>', $p or die "$p: $!";
    binmode $fh;
    print {$fh} $t;
    close $fh;
    return;
}

# Apache runs a shim that hands the request to the real script unchanged (the
# tree's scripts carry no mode bit; t/integration/261 does the same).
my $TRACE = "$site/dav-trace.log";
# DavTrace (t/lib) notes the script's start and its end, so the test can tell
# "the engine ran and cleaned up" from "the engine never ran".
spit( "$cgibin/lazysite-dav.pl", <<"SHIM" );
#!$^X
\$ENV{LAZYSITE_TEST_TRACE}     = '$TRACE';
\$ENV{LAZYSITE_TEST_TRACE_DIR} = '$docroot/content';
\$ENV{PERL5OPT} = '-I$root/lib -I$root/t/lib -MDavTrace';
exec { \$^X } \$^X, '$root/lazysite-dav.pl' or die "exec: \$!\\n";
SHIM
chmod 0755, "$cgibin/lazysite-dav.pl";

my $PORT = do {
    my $l = IO::Socket::INET->new( LocalAddr => '127.0.0.1', Proto => 'tcp' )
        or die 'no port';
    my $p = $l->sockport;
    close $l;
    $p;
};

# ScriptAlias /dav, as installers/hestia/lazysite-cgi.tpl:27 has it. Timeout is
# short so the stalled client costs seconds, not Apache's default 60.
# CGIPassAuth hands the Authorization header to the script, which Apache
# otherwise withholds.
my $TIMEOUT = 3;
spit( "$site/httpd.conf", <<"CONF" );
ServerRoot "$site"
ServerName 127.0.0.1
Listen 127.0.0.1:$PORT
PidFile "$site/httpd.pid"
ErrorLog "$site/logs/error.log"
Timeout $TIMEOUT
LoadModule mpm_prefork_module $MODS/mod_mpm_prefork.so
LoadModule authz_core_module $MODS/mod_authz_core.so
LoadModule alias_module $MODS/mod_alias.so
LoadModule mime_module $MODS/mod_mime.so
LoadModule cgi_module $MODS/mod_cgi.so
TypesConfig /etc/mime.types
DocumentRoot "$docroot"
ScriptAlias /dav "$cgibin/lazysite-dav.pl"
<Directory "$cgibin">
    Options +ExecCGI
    CGIPassAuth On
    Require all granted
</Directory>
<Directory "$docroot">
    Options None
    AllowOverride None
    Require all granted
</Directory>
CONF

sub apache { return system( $APACHE, '-f', "$site/httpd.conf", '-k', $_[0] ) == 0 }

sub slurp_log {
    open my $fh, '<', "$site/logs/error.log" or return '';
    local $/;
    my $t = <$fh>;
    close $fh;
    return $t // '';
}

unless ( apache('start') ) {
    plan skip_all => 'apache2 would not start here: ' . slurp_log();
}
END { apache('stop') if $APACHE && -f "$site/httpd.pid" }

# The .tmp names seen in the content directory while a request was in flight.
my %SEEN;

# One request on a raw socket. $act is 'close' (half-close after the bytes) or
# 'stall' (send, then wait for Apache). Returns the raw response ('' if none).
sub raw_put {
    my ( $path, $claimed, $body, $act ) = @_;
    my $sock = IO::Socket::INET->new( PeerAddr => "127.0.0.1:$PORT", Proto => 'tcp' )
        or return;
    my $head = "PUT /dav$path HTTP/1.1\r\nHost: 127.0.0.1\r\n"
        . "Authorization: $s->{auth}\r\nContent-Length: $claimed\r\n"
        . "Connection: close\r\n\r\n";
    syswrite $sock, $head . $body;
    $sock->shutdown(1) if $act eq 'close';
    my $out = '';
    my $t0  = time;
    local $SIG{ALRM} = sub { };
    while ( time - $t0 < $TIMEOUT + 8 ) {
        $SEEN{$_} = 1 for tmps();
        my $rin = '';
        vec( $rin, fileno($sock), 1 ) = 1;
        next unless select( $rin, undef, undef, 0.2 );
        my $n = sysread $sock, my $buf, 65536;
        last unless $n;
        $out .= $buf;
    }
    close $sock;
    return $out;
}

sub propfind {
    my ($path) = @_;
    my $sock = IO::Socket::INET->new( PeerAddr => "127.0.0.1:$PORT", Proto => 'tcp' )
        or return '';
    syswrite $sock, "PROPFIND /dav$path HTTP/1.1\r\nHost: 127.0.0.1\r\n"
        . "Authorization: $s->{auth}\r\nDepth: 1\r\nContent-Length: 0\r\n"
        . "Connection: close\r\n\r\n";
    my $out = '';
    my $t0  = time;
    while ( time - $t0 < 10 ) {
        my $n = sysread $sock, my $buf, 65536;
        last unless $n;
        $out .= $buf;
    }
    close $sock;
    return $out;
}

sub trace_lines {
    open my $fh, '<', $TRACE or return ();
    my @l = <$fh>;
    close $fh;
    chomp @l;
    return @l;
}

sub tmps {
    opendir my $dh, "$docroot/content" or return ();
    my @t = grep { /\.tmp\.\d+\z/ } readdir $dh;
    closedir $dh;
    return @t;
}

# The control: a whole PUT through this Apache is stored, so "nothing stored"
# below is not a configuration that refuses every PUT.
{
    my $r = raw_put( '/content/whole.bin', 100, 'w' x 100, 'close' );
    like( $r, qr{\AHTTP/1\.1 201}, 'control: a whole PUT through Apache is a 201' )
        or diag( $r, slurp_log() );
    is( -s "$docroot/content/whole.bin", 100, 'and is stored' );
}

for my $case ( [ 'close', 'cut' ], [ 'stall', 'stuck' ] ) {
    my ( $act, $name ) = @$case;
    subtest "a short body, the client " . ( $act eq 'close' ? 'half-closes' : 'stalls' ) => sub {
        my $t0     = time;
        my $before = () = trace_lines();
        %SEEN = ();
        my $r  = raw_put( "/content/$name.bin", 1000, 'x' x 100, $act );
        note( sprintf '%s: %.1f s, response: %s', $act, time - $t0,
            length $r ? ( split /\r\n/, $r )[0] : '(none)' );
        # Apache ends the CGI itself once its read of the client fails; give the
        # guard a moment.
        for ( 1 .. 15 ) { last if trace_lines() >= $before + 2; sleep 0.1 }
        for ( 1 .. 30 ) { last unless tmps(); sleep 0.1 }

        # Measured: Apache itself answers a request body that ends short (400 on
        # a half-close, 408 once its Timeout runs out on a stall) and discards
        # whatever the CGI wrote, so the client never sees the engine's own 400
        # text (t/unit/dav/33 asserts that). That is the front's layer; what
        # must hold here is that the client is never told it worked.
        unlike( $r, qr{\AHTTP/1\.1 2}, 'the client is not told it worked' );
        like( $r, qr{\AHTTP/1\.1 4\d\d}, 'it is told it failed (Apache\'s own answer)' )
            or diag($r);

        # Apache ends a CGI whose client body failed with SIGTERM; the SM1114
        # handler turns that into an exit so the END guard removes the temp. A
        # process killed by the default SIGTERM leaves no end line. Measured:
        # on a half-close Apache fails its read at once and ends the CGI before
        # perl has loaded DavTrace, so the engine may not run at all; on a
        # stall it runs for the whole Timeout with its temp on disk, then is
        # ended. Either way every start has its end.
        my @all   = trace_lines();
        my @new   = @all[ $before .. $#all ];
        my $begun = grep { /\Abegin / } @new;
        my $ended = grep { /\Aend pid=\d+ tmps=\z/ } @new;
        is( $ended, $begun, 'every engine start ended by its own END guard, no temp left' )
            or diag( join "\n", @new );
        if ( $act eq 'stall' ) {
            is( $begun, 1, 'the engine ran for the stalled client' );
            ok( scalar keys %SEEN, 'with a temp on disk while Apache waited ('
                    . join( ',', keys %SEEN ) . ')' );
        }
        unlike( slurp_log(), qr/path=content\/\Q$name\E\.bin/,
            'and logged no successful put of the name' );
        ok( !-e "$docroot/content/$name.bin", 'no file at the target' );
        is_deeply( [ tmps() ], [], 'no .tmp.<pid> sibling' )
            or diag( slurp_log() );
        my $p = propfind('/content/');
        like( $p, qr/whole\.bin/, 'PROPFIND lists the real file' );
        unlike( $p, qr/\Q$name\E\.bin/, 'and neither the target nor a temp' );
    };
}

done_testing();
