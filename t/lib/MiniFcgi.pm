package MiniFcgi;
# A minimal FastCGI *client* for the test suite (SM142): speaks just enough
# of the FCGI record protocol to drive one responder request over a unix
# socket - BEGIN_REQUEST, PARAMS, empty STDIN, then collects STDOUT until
# END_REQUEST. Pure core (Socket), no external deps, so the suite can test
# the FCGI accept loop without an FCGI-speaking web server.
use strict;
use warnings;
use Socket   qw(AF_UNIX SOCK_STREAM sockaddr_un);
use Exporter qw(import);
our @EXPORT_OK = qw(fcgi_request);

my $FCGI_BEGIN_REQUEST = 1;
my $FCGI_PARAMS        = 4;
my $FCGI_STDIN         = 5;
my $FCGI_STDOUT        = 6;
my $FCGI_STDERR        = 7;
my $FCGI_END_REQUEST   = 3;
my $FCGI_RESPONDER     = 1;

sub _record {
    my ( $type, $content ) = @_;
    my $len = length $content;
    my $pad = ( 8 - ( $len % 8 ) ) % 8;
    return pack( 'CCnnCC', 1, $type, 1, $len, $pad, 0 )
        . $content
        . ( "\0" x $pad );
}

sub _nv_pair {
    my ( $name, $value ) = @_;
    my $out = '';
    for my $l ( length $name, length $value ) {
        $out .= $l < 128 ? pack( 'C', $l ) : pack( 'N', $l | 0x80000000 );
    }
    return $out . $name . $value;
}

# fcgi_request($socket_path, \%params, [$body]) -> { stdout, stderr, status }
# stdout is the raw CGI response (headers + body); status is the
# END_REQUEST app status. Dies on connect/protocol failure.
sub fcgi_request {
    my ( $path, $params, $body ) = @_;
    $body //= '';
    socket( my $s, AF_UNIX, SOCK_STREAM, 0 ) or die "socket: $!";
    connect( $s, sockaddr_un($path) )        or die "connect $path: $!";
    binmode $s;
    local $SIG{PIPE} = 'IGNORE';    # a worker may close early; read what came

    my $req = _record( $FCGI_BEGIN_REQUEST, pack( 'nCx5', $FCGI_RESPONDER, 0 ) );
    my $nv  = join '', map { _nv_pair( $_, $params->{$_} // '' ) } sort keys %{$params};
    $req .= _record( $FCGI_PARAMS, $nv );
    $req .= _record( $FCGI_PARAMS, '' );
    $req .= _record( $FCGI_STDIN,  $body ) if length $body;
    $req .= _record( $FCGI_STDIN,  '' );
    # syswrite, not print: a buffered print would sit unflushed while we
    # block in the read loop below - the worker would never see the request.
    my $off = 0;
    while ( $off < length $req ) {
        my $w = syswrite( $s, $req, length($req) - $off, $off );
        die "syswrite: $!" unless defined $w;
        $off += $w;
    }

    my ( $stdout, $stderr, $status ) = ( '', '', undef );
    my $buf = '';
    while (1) {
        my $r = sysread( $s, $buf, 65536, length $buf );
        last if !defined $r || $r == 0;
        while ( length $buf >= 8 ) {
            my ( undef, $type, undef, $clen, $plen ) = unpack 'CCnnC', $buf;
            last if length $buf < 8 + $clen + $plen;
            my $content = substr $buf, 8, $clen;
            substr( $buf, 0, 8 + $clen + $plen ) = '';
            if    ( $type == $FCGI_STDOUT ) { $stdout .= $content }
            elsif ( $type == $FCGI_STDERR ) { $stderr .= $content }
            elsif ( $type == $FCGI_END_REQUEST ) {
                $status = unpack 'N', $content;
                close $s;
                return { stdout => $stdout, stderr => $stderr, status => $status };
            }
        }
    }
    close $s;
    die "connection closed before END_REQUEST (got " . length($stdout) . " bytes)\n"
        unless defined $status;
    return { stdout => $stdout, stderr => $stderr, status => $status };
}

1;
