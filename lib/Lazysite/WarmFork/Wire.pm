package Lazysite::WarmFork::Wire;

# SM1226 (SM1082 C3, SM1164 D5): THE WIRE BETWEEN A FRONT END AND THE WARM-FORK
# PARENT - FastCGI records, both ways, and the one place the parent's socket is named.
#
# The warm-fork parent (Lazysite::WarmFork) listens on a Unix socket and speaks
# FastCGI's responder role, one request per connection, so a web server could
# connect to it as it connects to the pool. The pool's front door is the client
# today: it relays /cgi-bin/lazysite-odoo.pl there instead of forking and
# exec'ing the CGI (lazysite-processor/front-door.pm, _front_warm).
#
# WHAT IS HERE: the record framing (record, nv_pairs, parse_nv), the socket's
# path (socket_for) and a client (request) that sends a request's parameters and
# body and returns what came back. Core modules only, and NO file-scope state: a
# pool worker loads this, and t/lint/269 reads what a worker keeps resident.
use strict;
use warnings;
use Socket     qw(AF_UNIX SOCK_STREAM sockaddr_un);
use IO::Select ();

our $VERSION = '0.1';

# The FastCGI record types and the one role this speaks (FastCGI 1.0, section 8).
sub FCGI_BEGIN_REQUEST ()     { return 1 }
sub FCGI_ABORT_REQUEST ()     { return 2 }
sub FCGI_END_REQUEST ()       { return 3 }
sub FCGI_PARAMS ()            { return 4 }
sub FCGI_STDIN ()             { return 5 }
sub FCGI_STDOUT ()            { return 6 }
sub FCGI_STDERR ()            { return 7 }
sub FCGI_GET_VALUES ()        { return 9 }
sub FCGI_GET_VALUES_RESULT () { return 10 }
sub FCGI_UNKNOWN_TYPE ()      { return 11 }
sub FCGI_RESPONDER ()         { return 1 }
sub FCGI_REQUEST_COMPLETE ()  { return 0 }
sub FCGI_UNKNOWN_ROLE ()      { return 3 }
sub FCGI_MAX_CONTENT ()       { return 65_535 }

# The parent's socket: the site's own lazysite/run/odoo-endpoint.sock, in the
# directory oomd's socket uses (0700, the request path's user, SM760). A Unix
# socket path is at most 104 bytes on every system lazysite runs on; a longer one
# is no socket at all, and the front door then runs the CGI as before. Returns
# ( $path ) or ( undef, $why ).
sub socket_for {
    my ($lazysite_dir) = @_;
    return ( undef, 'no lazysite directory' ) unless defined $lazysite_dir && length $lazysite_dir;
    my $p = "$lazysite_dir/run/odoo-endpoint.sock";
    return ( undef, "the socket path is " . length($p) . ' bytes; a Unix socket path is at most 103' )
        if length $p > 103;
    return ($p);
}

# One record: version 1, the type, request id 1 (one request per connection),
# the content and padding to a multiple of eight.
sub record {
    my ( $type, $content, $id ) = @_;
    $content //= '';
    my $pad = ( 8 - ( length($content) % 8 ) ) % 8;
    return pack( 'CCnnCC', 1, $type, $id // 1, length $content, $pad, 0 ) . $content . ( "\0" x $pad );
}

# A stream (PARAMS, STDIN, STDOUT) as records of at most MAX_CONTENT bytes, and
# the empty record that ends it.
sub stream {
    my ( $type, $data, $id ) = @_;
    my $out = '';
    for ( my $o = 0; $o < length( $data // '' ); $o += 32_768 ) {
        $out .= record( $type, substr( $data, $o, 32_768 ), $id );
    }
    return $out . record( $type, '', $id );
}

sub _len { my ($n) = @_; return $n < 128 ? pack( 'C', $n ) : pack( 'N', $n | 0x8000_0000 ) }

# Name-value pairs, FastCGI's encoding (a length is one byte below 128, else four
# with the top bit set).
sub nv_pairs {
    my ($h) = @_;
    return join '', map {
        my $v = $h->{$_} // '';
        _len( length $_ ) . _len( length $v ) . $_ . $v
    } sort keys %$h;
}

# The reverse: ( \%pairs ) or ( undef, $why ) for a malformed block.
sub parse_nv {
    my ($buf) = @_;
    my %h;
    my $o = 0;
    my $n = length $buf;
    while ( $o < $n ) {
        my @l;
        for ( 1 .. 2 ) {
            return ( undef, 'a name-value length runs past the block' ) if $o >= $n;
            my $b = unpack( 'C', substr( $buf, $o, 1 ) );
            if ( $b < 128 ) { push @l, $b; $o += 1; next }
            return ( undef, 'a name-value length runs past the block' ) if $o + 4 > $n;
            push @l, unpack( 'N', substr( $buf, $o, 4 ) ) & 0x7fff_ffff;
            $o += 4;
        }
        return ( undef, 'a name-value pair runs past the block' ) if $o + $l[0] + $l[1] > $n;
        my $k = substr( $buf, $o, $l[0] );
        $o += $l[0];
        $h{$k} = substr( $buf, $o, $l[1] );
        $o += $l[1];
    }
    return ( \%h );
}

# THE CLIENT. Connects to $path, sends the parameters and the body as one
# request, and reads the STDOUT stream until END_REQUEST, writing and reading
# together (the far end may answer before it has read the body - a 413 - and
# must not be left blocked on a full socket). Gives up at $o{timeout} seconds.
#
# Returns:
#   { connected => 0, why }                  nothing reached the parent: the
#                                            caller may run the request another way
#   { connected => 1, out, complete, timed_out, why }
#                                            the parent took the request; whatever
#                                            happened next, it is not to be re-run
#                                            (a write may have been made)
sub request {
    my ( $path, $params, $body, %o ) = @_;
    $body //= '';
    my $timeout = $o{timeout} // 120;
    socket( my $sk, AF_UNIX, SOCK_STREAM, 0 ) or return { connected => 0, why => "socket: $!" };
    connect( $sk, sockaddr_un($path) ) or return { connected => 0, why => "connect: $!" };
    binmode $sk;
    local $SIG{PIPE} = 'IGNORE';

    my $req = record( FCGI_BEGIN_REQUEST, pack( 'nCx5', FCGI_RESPONDER, 0 ) )
        . stream( FCGI_PARAMS, nv_pairs($params) )
        . stream( FCGI_STDIN,  $body );
    my ( $sent, $in, $out ) = ( 0, '', '' );
    my $rsel     = IO::Select->new($sk);
    my $wsel     = IO::Select->new($sk);
    my $deadline = time + $timeout;
    my ( $complete, $why ) = ( 0, undef );
IO: while (1) {
        my $left = $deadline - time;
        if ( $left <= 0 ) { close $sk; return { connected => 1, out => $out, complete => 0, timed_out => 1, why => 'timed out' } }
        my ( $r, $w ) = IO::Select->select( $rsel, ( $wsel->count ? $wsel : undef ), undef, $left );
        if ( $w && @$w ) {
            my $n = syswrite( $sk, $req, length($req) - $sent, $sent );
            if   ( !defined $n ) { $wsel->remove($sk) } # the far end closed its read side
            else                 { $sent += $n }
            $wsel->remove($sk) if $sent >= length $req;
        }
        next unless $r && @$r;
        my $n = sysread( $sk, $in, 65_536, length $in );
        if ( !$n ) { $why = 'the parent closed the connection before the end of the request'; last IO }
        while ( length $in >= 8 ) {
            my ( undef, $type, undef, $clen, $plen ) = unpack 'CCnnC', $in;
            last if length $in < 8 + $clen + $plen;
            my $c = substr $in, 8, $clen;
            substr( $in, 0, 8 + $clen + $plen, '' );
            $out .= $c if $type == FCGI_STDOUT;
            if ( $type == FCGI_END_REQUEST ) { $complete = 1; last IO }
        }
    }
    close $sk;
    return { connected => 1, out => $out, complete => $complete, timed_out => 0, ( defined $why ? ( why => $why ) : () ) };
}

1;
