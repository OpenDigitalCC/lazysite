package NginxHarness;
# SM283: render a shipped front-end config, and (optionally) run nginx against
# it. Shared by t/lint/34 (does it parse) and t/integration/42 (does it behave),
# because both need the same rendering and neither is worth doing twice.
#
# Why this exists at all: SM283 was a defect in an nginx config, found on a live
# site, on a host that had no nginx. Every check we had was a text match, and a
# text match can only tell you a line is present - which it always was, in the
# wrong file. It cannot tell you whether `error_page 418` fires where intended,
# whether an exact `location =` outranks a real file on disk, or which of two
# locations nginx actually selects.
#
# That last one is not hypothetical. The first version of these tests asserted
# that `^~` on the /lazysite/ deny was what stopped the extension regex serving
# a pre-install backup. Running the server showed it was not: the extension
# regex is NESTED inside `location /`, so a URI matching the longer /lazysite/
# prefix never reaches it either way. The protection was real, the explanation
# was wrong, and no amount of text matching would ever have said so.
use strict;
use warnings;
use Exporter 'import';
use File::Path       qw(make_path);
use IO::Socket::INET ();

our @EXPORT_OK = qw(nginx_bin render write_conf free_port http_get
    start_nginx stop_nginx);

# Hestia's own nginx.conf defines this at http scope and its bandwidth
# accounting reads the resulting file, so the proxy template uses it exactly as
# Hestia's stock template does. It is a dependency the template does not own:
# outside Hestia, `access_log ... bytes` refuses to start. Declared here so the
# harness reproduces the context the template is rendered into, rather than
# passing by removing the dependency from the file under test.
our $HESTIA_LOG_FORMAT = q{log_format bytes '$body_bytes_sent';};

sub nginx_bin {
    for my $p (qw(/usr/sbin/nginx /usr/local/sbin/nginx /usr/bin/nginx)) {
        return $p if -x $p;
    }
    my $which = `sh -c 'command -v nginx 2>/dev/null'`;
    chomp $which;
    return ( length $which && -x $which ) ? $which : undef;
}

# A free TCP port, by asking the kernel for one and handing it back.
sub free_port {
    my $s = IO::Socket::INET->new(
        LocalAddr => '127.0.0.1',
        Proto     => 'tcp',
        Listen    => 1,
    ) or die "free_port: $!";
    my $port = $s->sockport;
    close $s;
    return $port;
}

# Substitute the template's placeholders. Hestia uses %name% and the lazysite
# nginx examples use __NAME__; one table covers both, so a new config in either
# style is renderable without touching the callers.
sub render {
    my ( $path, %v ) = @_;
    open my $fh, '<', $path or die "$path: $!";
    my $t = do { local $/; <$fh> };
    close $fh;

    # Longest first: %proxy_ssl_port% must not be eaten by %proxy_port%.
    for my $k ( sort { length($b) <=> length($a) } keys %v ) {
        my $val = $v{$k};
        $t =~ s{\Q$k\E}{$val}g;
    }
    # Log paths are absolute in the templates and nginx OPENS them at config
    # test time, so they have to land inside the harness prefix.
    $t =~ s{/var/log/[^\s;]*/}{$v{'%%LOGDIR%%'}}g if $v{'%%LOGDIR%%'};
    return $t;
}

# Write a minimal http{} wrapping one rendered server block. Returns the conf
# path. `$hestia` adds the log_format the Hestia templates depend on, and
# `extra_http` injects directives into the http{} block - which is how a test
# reproduces a front end that sets proxy defaults globally, versus one that
# sets nothing and leaves the template to state its own needs.
sub write_conf {
    my ( $prefix, $site_conf, %o ) = @_;
    make_path( "$prefix/logs", "$prefix/conf" );
    open my $sf, '>', "$prefix/conf/site.conf" or die $!;
    print {$sf} $site_conf;
    close $sf;

    # `include fastcgi_params;` is RELATIVE, and nginx resolves it against the
    # prefix - which on a real host is /etc/nginx, where the file lives. The
    # harness prefix is a tempdir, so the file has to be put where the config
    # expects it rather than the config changed to suit the harness.
    if ( -f '/etc/nginx/fastcgi_params' ) {
        open my $in,  '<', '/etc/nginx/fastcgi_params' or die $!;
        open my $out, '>', "$prefix/fastcgi_params"    or die $!;
        print {$out} do { local $/; <$in> };
        close $in;
        close $out;
    }

    my $extra = $o{extra_http}             ? "    $o{extra_http}\n"                 : '';
    my $fmt   = $o{hestia}                 ? "    $HESTIA_LOG_FORMAT\n"             : '';
    my $mime  = -f '/etc/nginx/mime.types' ? "    include /etc/nginx/mime.types;\n" : '';
    open my $cf, '>', "$prefix/nginx.conf" or die $!;
    print {$cf} <<"CONF";
worker_processes 1;
daemon on;
pid $prefix/nginx.pid;
error_log $prefix/logs/error.log;
events { worker_connections 64; }
http {
$mime$fmt    access_log $prefix/logs/http-access.log;
    client_body_temp_path $prefix/tmp-body;
    proxy_temp_path       $prefix/tmp-proxy;
    fastcgi_temp_path     $prefix/tmp-fastcgi;
    uwsgi_temp_path       $prefix/tmp-uwsgi;
    scgi_temp_path        $prefix/tmp-scgi;
    proxy_connect_timeout 1s;
$extra    include $prefix/conf/site.conf;
}
CONF
    close $cf;
    return "$prefix/nginx.conf";
}

sub start_nginx {
    my ( $bin, $prefix ) = @_;
    my $out = `\Q$bin\E -p \Q$prefix\E -c \Q$prefix/nginx.conf\E 2>&1`;
    my $rc  = $? >> 8;
    return ( $rc, $out );
}

sub stop_nginx {
    my ( $bin, $prefix ) = @_;
    return unless -f "$prefix/nginx.pid";
    system("\Q$bin\E -p \Q$prefix\E -c \Q$prefix/nginx.conf\E -s quit >/dev/null 2>&1");
    for ( 1 .. 50 ) {
        return unless -f "$prefix/nginx.pid";
        select undef, undef, undef, 0.1;
    }
    return;
}

# One HTTP/1.0 GET. Returns (status, body, \%headers); status 0 on no answer.
# Deliberately hand-rolled: the point is to observe exactly what the front end
# said, and a user agent that follows redirects or reuses connections would
# obscure the thing under test.
sub http_get {
    my ( $port, $path, %o ) = @_;
    my $class = 'IO::Socket::INET';
    my %args  = (
        PeerAddr => '127.0.0.1',
        PeerPort => $port,
        Proto    => 'tcp',
        Timeout  => 10,
    );
    if ( $o{tls} ) {
        require IO::Socket::SSL;
        $class = 'IO::Socket::SSL';
        $args{SSL_verify_mode} = 0;                   # a self-signed harness cert
            # SNI is a parameter, not a constant. A test that puts a real Apache
            # behind this needs to control the name in the HANDSHAKE separately
            # from the name in the REQUEST, because the whole class of defect at
            # that hop is the two disagreeing.
        $args{SSL_hostname} = $o{sni} || $o{host} || 'lazysite.test';
    }
    my $s    = $class->new(%args) or return ( 0, '', {} );
    my $host = $o{host} || 'lazysite.test';
    print {$s} "GET $path HTTP/1.0\r\nHost: $host\r\nConnection: close\r\n\r\n";
    my $raw = do { local $/; <$s> };
    close $s;
    return ( 0, '', {} ) unless defined $raw;

    my ( $head, $body ) = split /\r?\n\r?\n/, $raw, 2;
    my ($status) = ( $head // '' ) =~ m{\A\S+\s+(\d+)};
    my %h;
    for my $line ( split /\r?\n/, ( $head // '' ) ) {
        next unless $line =~ /\A([^:]+):\s*(.*)\z/;
        $h{ lc $1 } = $2;
    }
    return ( $status // 0, $body // '', \%h );
}

1;
