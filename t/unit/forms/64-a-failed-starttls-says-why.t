#!/usr/bin/perl
# SM1110 (0.15.7 test plan, "Found while getting mail to send", U7): "STARTTLS
# fails on a hostname mismatch with only 'STARTTLS failed'... the message should
# say 'certificate is for isp.cloudient.net, not mail.explore.lazysite.io'."
#
# A local SMTP server that offers STARTTLS and then presents a certificate issued
# for other names. The test trusts that certificate (SSL_CERT_FILE) so the ONE
# thing wrong is the name; without the trust the failure is the certificate
# itself, and a server that refuses STARTTLS is a third case. Each says its own
# reason, in the send and in the Validate action.
use strict;
use warnings;
use Test::More;
use JSON::PP   ();
use File::Path qw(make_path);
use IO::Socket::INET;
use FindBin;
use lib "$FindBin::Bin/../../lib", "$FindBin::Bin/../../../lib";
use TestHelper qw(repo_root site_tempdir);

plan skip_all => 'IO::Socket::SSL is not installed' unless eval { require IO::Socket::SSL; 1 };
my $openssl = -x '/usr/bin/openssl' ? '/usr/bin/openssl' : '';
plan skip_all => 'no openssl to make a certificate' unless $openssl;

my $script = repo_root() . '/plugins/form-smtp.pl';
my $d      = site_tempdir();
make_path("$d/lazysite/forms");
sub spit { my ( $p, $t ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh; return }

my $mk = do {
    open my $so, '>&', \*STDOUT or die;
    open my $se, '>&', \*STDERR or die;
    open STDOUT, '>', '/dev/null' or die;
    open STDERR, '>', '/dev/null' or die;
    my $rc = system( $openssl, 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-keyout', "$d/k.pem", '-out', "$d/c.pem",
        '-days', '2', '-subj', '/CN=isp.cloudient.net', '-addext',
        'subjectAltName=DNS:isp.cloudient.net,DNS:mail.cloudient.net' );
    open STDOUT, '>&', $so or die;
    open STDERR, '>&', $se or die;
    $rc;
};
plan skip_all => 'openssl could not make a certificate' if $mk != 0;

# One server, two ports: the first offers STARTTLS and presents the certificate,
# the second answers STARTTLS with a refusal.
sub serve {
    my ($refuse) = @_;
    my $srv = IO::Socket::INET->new( LocalAddr => '127.0.0.1', LocalPort => 0, Listen => 5, ReuseAddr => 1 )
        or die "cannot listen: $!";
    my $port = $srv->sockport;
    my $pid  = fork();
    die "fork: $!" unless defined $pid;
    if ( $pid == 0 ) {
        local $SIG{ALRM} = sub { exit 0 };
        alarm 60;
        while ( my $c = $srv->accept ) {
            $c->autoflush(1);
            print {$c} "220 mock ready\r\n";
            while ( my $line = <$c> ) {
                if ( $line =~ /^(?:EHLO|HELO)\b/i ) { print {$c} "250-mock\r\n250 STARTTLS\r\n" }
                elsif ( $line =~ /^STARTTLS/i ) {
                    if ($refuse) { print {$c} "454 TLS not available\r\n"; next }
                    print {$c} "220 go ahead\r\n";
                    IO::Socket::SSL->start_SSL( $c, SSL_server => 1, SSL_cert_file => "$d/c.pem", SSL_key_file => "$d/k.pem" );
                    last;
                }
                elsif ( $line =~ /^QUIT/i ) { print {$c} "221 bye\r\n"; last }
                else                        { print {$c} "250 OK\r\n" }
            }
            close $c;
        }
        exit 0;
    }
    close $srv;
    return ( $port, $pid );
}
my ( $tls_port, $tls_pid ) = serve(0);
my ( $no_port,  $no_pid )  = serve(1);

sub conf { my ( $host, $port ) = @_; spit( "$d/lazysite/forms/smtp.conf", "method: smtp\nhost: $host\nport: $port\ntls: starttls\nfrom: a\@example.org\n" ) }

sub send_it {
    local $ENV{DOCUMENT_ROOT} = $d;
    local $ENV{LAZYSITE_LOG_LEVEL} = 'ERROR';
    open( my $fh, '-|', 'sh', '-c', "echo '{\"config\":{\"to\":\"ada\@example.net\"},\"form\":{\"message\":\"hi\"}}' | $^X \Q$script\E --pipe 2>/dev/null" );
    my $res = do { local $/; <$fh> };
    close $fh;
    return JSON::PP::decode_json( $res || '{}' );
}
sub validate {
    local $ENV{LAZYSITE_LOG_LEVEL} = 'ERROR';
    my $o = qx($^X \Q$script\E --scan --docroot \Q$d\E 2>/dev/null);
    return JSON::PP::decode_json( $o || '{}' );
}

subtest 'a certificate for other names' => sub {
    local $ENV{SSL_CERT_FILE} = "$d/c.pem";
    conf( 'localhost', $tls_port );
    my $r = send_it();
    ok( !$r->{ok}, 'the send fails' );
    like( $r->{error} // '', qr/certificate is for isp\.cloudient\.net, mail\.cloudient\.net, not localhost/,
        'and says whose certificate it was and what was connected to' )
        or diag( $r->{error} // '' );
    my $v = validate();
    is( $v->{stage}, 'tls', 'Validate: the tls stage' );
    like( $v->{error} // '', qr/certificate is for isp\.cloudient\.net, mail\.cloudient\.net, not localhost/,
        '...and it says the same' );
};

subtest 'a certificate nobody trusts' => sub {
    local $ENV{SSL_CERT_FILE} = '/nonexistent/ca.pem';
    conf( '127.0.0.1', $tls_port );
    my $r = send_it();
    ok( !$r->{ok}, 'the send fails' );
    like( $r->{error} // '', qr/\ASTARTTLS failed: .*verif/i, 'and says the TLS library\'s reason, not just that it failed' )
        or diag( $r->{error} // '' );
};

subtest 'a server that refuses STARTTLS' => sub {
    conf( '127.0.0.1', $no_port );
    my $r = send_it();
    ok( !$r->{ok}, 'the send fails' );
    like( $r->{error} // '', qr/\ASTARTTLS failed: the server replied 454 TLS not available/, 'and quotes the server\'s reply' )
        or diag( $r->{error} // '' );
    like( validate()->{error} // '', qr/not offer STARTTLS/, 'Validate keeps its advice for this case' );
};

kill 'TERM', $_ for $tls_pid, $no_pid;
waitpid $_, 0 for $tls_pid, $no_pid;
done_testing;
