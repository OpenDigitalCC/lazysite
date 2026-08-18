package ApacheHarness;
# A real Apache with MORE THAN ONE TLS VHOST, which is the only configuration
# that can show the defect this exists for.
#
# A single-vhost fixture answers every request from the same vhost whatever the
# handshake said, so the SNI/Host disagreement has nothing to disagree about.
# That is the most likely reason lazysite-proxy.stpl shipped able to take a
# site down: everything it was tested against had one vhost.
#
# The FIRST vhost declared is Apache's default for the listener - the one it
# falls back to when the handshake carries no SNI - so a test asserts against
# the SECOND, which is the position a real site is in.
use strict;
use warnings;
use File::Path qw(make_path);
use Exporter 'import';

our @EXPORT_OK = qw(apache_bin apache_module_dir make_certs start_apache stop_apache);

sub apache_bin {
    for my $p (qw(/usr/sbin/apache2 /usr/sbin/httpd /usr/local/sbin/apache2)) {
        return $p if -x $p;
    }
    return;
}

sub apache_module_dir {
    for my $d (qw(/usr/lib/apache2/modules /usr/libexec/apache2 /usr/lib64/httpd/modules)) {
        return $d if -d $d && -f "$d/mod_ssl.so";
    }
    return;
}

# Self-signed certs, one per name. openssl is invoked with a list-form system()
# so a name never reaches a shell.
sub make_certs {
    my ( $dir, @names ) = @_;
    make_path($dir);
    for my $n (@names) {
        my $rc = system(
            'openssl', 'req',         '-x509', '-newkey', 'rsa:2048', '-nodes',
            '-keyout', "$dir/$n.key", '-out',  "$dir/$n.crt",
            '-days',   '2',           '-subj', "/CN=$n",
            '-addext', "subjectAltName=DNS:$n",
        );
        die "openssl failed for $n (rc=$rc)" if $rc != 0;
    }
    return;
}

# @vhosts is a list of [ name, docroot ]. The first is the default vhost.
sub start_apache {
    my ( $prefix, $port, $certs, @vhosts ) = @_;
    my $mods = apache_module_dir() or die 'no apache module dir';
    make_path("$prefix/logs");

    # log_config is BUILT IN on Debian's apache2 and loading it is a fatal
    # config error, so it is deliberately absent from this list.
    my @load = (
        [ mpm_event_module  => 'mod_mpm_event.so' ],
        [ authz_core_module => 'mod_authz_core.so' ],
        [ ssl_module        => 'mod_ssl.so' ],
        [ mime_module       => 'mod_mime.so' ],
        [ dir_module        => 'mod_dir.so' ],
    );

    my $conf = "ServerRoot /etc/apache2\nServerName 127.0.0.1\n"
        . "PidFile $prefix/httpd.pid\nErrorLog $prefix/logs/apache-error.log\n";
    $conf .= "LoadModule $_->[0] $mods/$_->[1]\n" for @load;
    $conf .= "TypesConfig /etc/mime.types\n" if -f '/etc/mime.types';
    $conf .= "Listen 127.0.0.1:$port\n";
    for my $v (@vhosts) {
        my ( $name, $root ) = @$v;
        $conf .= <<"VH";
<VirtualHost 127.0.0.1:$port>
    ServerName $name
    DocumentRoot $root
    SSLEngine on
    SSLCertificateFile $certs/$name.crt
    SSLCertificateKeyFile $certs/$name.key
    <Directory $root>
        Require all granted
    </Directory>
</VirtualHost>
VH
    }
    open my $fh, '>', "$prefix/httpd.conf" or die $!;
    print {$fh} $conf;
    close $fh;

    my $bin = apache_bin() or die 'no apache binary';
    my $out = `\Q$bin\E -f \Q$prefix/httpd.conf\E -k start 2>&1`;
    my $rc  = $? >> 8;
    return ( $rc, $out );
}

sub stop_apache {
    my ($prefix) = @_;
    my $bin = apache_bin() or return;
    return unless -f "$prefix/httpd.conf";
    system("\Q$bin\E -f \Q$prefix/httpd.conf\E -k stop >/dev/null 2>&1");
    for ( 1 .. 50 ) {
        return unless -f "$prefix/httpd.pid";
        select undef, undef, undef, 0.1;
    }
    return;
}

1;
