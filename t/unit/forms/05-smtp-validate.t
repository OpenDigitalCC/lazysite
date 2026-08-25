#!/usr/bin/perl
# SM137: the SMTP "Validate connection" action - staged diagnosis that names the
# failing stage (config / sendmail / host / port / TLS / auth). Network stages are
# exercised against a tiny in-test SMTP server (greets, answers EHLO, refuses
# STARTTLS and AUTH), so the stage logic is tested for real without a mail server.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use IO::Socket::INET;
use JSON::PP qw(decode_json);
use FindBin;

my $root   = "$FindBin::Bin/../../..";
my $plugin = "$root/plugins/form-smtp.pl";

my $d = tempdir( CLEANUP => 1 );
make_path("$d/lazysite/forms");

sub conf {
    open my $fh, '>', "$d/lazysite/forms/smtp.conf" or die $!;
    print {$fh} $_[0];
    close $fh;
}

sub validate {
    my $out = qx($^X \Q$plugin\E --scan --docroot \Q$d\E 2>/dev/null);
    return eval { decode_json($out) } // { _raw => $out };
}

# --- config + sendmail stages -------------------------------------------------
unlink "$d/lazysite/forms/smtp.conf";
is( validate()->{stage}, 'config', 'no smtp.conf -> stage config' );

conf("method: sendmail\nsendmail_path: /bin/true\n");
my $sm = validate();
ok( $sm->{ok}, 'sendmail with an executable path validates ok' );

conf("method: sendmail\nsendmail_path: /nonexistent/sendmail\n");
is( validate()->{stage}, 'sendmail', 'missing sendmail binary -> stage sendmail' );

# --- host + port stages --------------------------------------------------------
conf("method: smtp\nhost: no-such-host.invalid\nport: 25\n");
is( validate()->{stage}, 'host', 'unresolvable name -> stage host' );

conf("method: smtp\nhost: 127.0.0.1\nport: 1\ntls: false\n");
is( validate()->{stage}, 'port', 'closed port -> stage port' );

# --- live stages against a mock SMTP server ------------------------------------
my $srv = IO::Socket::INET->new(
    LocalAddr => '127.0.0.1', LocalPort => 0, Listen => 5, ReuseAddr => 1 )
    or die "cannot listen: $!";
my $port = $srv->sockport;

my $pid = fork();
die "fork: $!" unless defined $pid;
if ( $pid == 0 ) {
    # The server: greet; EHLO -> capabilities (incl. AUTH so the client tries);
    # STARTTLS -> refused; AUTH -> 535; QUIT -> 221.
    local $SIG{ALRM} = sub { exit 0 };
    alarm 60;
    while ( my $c = $srv->accept ) {
        $c->autoflush(1);
        print {$c} "220 mock ESMTP ready\r\n";
        while ( my $line = <$c> ) {
            $line =~ s/[\r\n]+\z//;
            if ( $line =~ /^(?:EHLO|HELO)\b/i ) {
                print {$c} "250-mock\r\n250-AUTH PLAIN LOGIN\r\n250 OK\r\n";
            }
            elsif ( $line =~ /^STARTTLS/i ) { print {$c} "454 TLS not available\r\n" }
            elsif ( $line =~ /^AUTH/i )     { print {$c} "535 authentication failed\r\n" }
            elsif ( $line =~ /^QUIT/i )     { print {$c} "221 bye\r\n"; last }
            else                            { print {$c} "250 OK\r\n" }
        }
        close $c;
    }
    exit 0;
}
close $srv;

# Plain session, no auth: everything checked passes.
conf("method: smtp\nhost: 127.0.0.1\nport: $port\ntls: false\n");
my $okr = validate();
ok( $okr->{ok}, 'mock server, no auth -> validates ok' )
    or diag explain $okr;
ok( ( grep { $_ eq 'connect' } @{ $okr->{checked} || [] } ), 'connect stage recorded' );

# STARTTLS refused by the server -> TLS stage.
conf("method: smtp\nhost: 127.0.0.1\nport: $port\ntls: starttls\n");
my $tl = validate();
is( $tl->{stage}, 'tls', 'server without STARTTLS -> stage tls' );
like( $tl->{error}, qr/STARTTLS/i, 'tls error names STARTTLS' );

# Credentials rejected -> auth stage.
SKIP: {
    skip 'Authen::SASL not installed', 2
        unless eval { require Authen::SASL; 1 };
    conf( "method: smtp\nhost: 127.0.0.1\nport: $port\ntls: false\n"
        . "auth: true\nusername: u\npassword: wrong\n" );
    my $au = validate();
    is( $au->{stage}, 'auth', 'rejected credentials -> stage auth' );
    like( $au->{error}, qr/535|credentials/i, 'auth error carries the server code' );
}

# Auth requested but no password set -> auth stage, actionable message.
conf("method: smtp\nhost: 127.0.0.1\nport: $port\ntls: false\nauth: true\nusername: u\n");
my $np = validate();
is( $np->{stage}, 'auth', 'auth without a password -> stage auth' );
like( $np->{error}, qr/no password/i, 'names the missing password' );

# SM524: the SM519 discipline - auth and tls are what the conf SAYS. `auth: 1`
# and `auth: yes` used to skip authentication silently (/^true$/i); a spelling
# the reader does not know must stop the run, never degrade to "no auth".
for my $spelling (qw(1 yes on true)) {
    conf( "method: smtp\nhost: 127.0.0.1\nport: $port\ntls: false\n"
        . "auth: $spelling\nusername: u\n" );
    my $r = validate();
    is( $r->{stage}, 'auth', "auth: $spelling reaches the auth stage" )
        or diag explain $r;
}
for my $spelling (qw(0 no off false)) {
    conf( "method: smtp\nhost: 127.0.0.1\nport: $port\ntls: false\n"
        . "auth: $spelling\nusername: u\n" );
    my $r = validate();
    ok( $r->{ok}, "auth: $spelling means no authentication" ) or diag explain $r;
}
conf("method: smtp\nhost: 127.0.0.1\nport: $port\ntls: false\nauth: maybe\nusername: u\n");
my $bad_auth = validate();
is( $bad_auth->{stage}, 'config', 'auth: maybe is refused at the config stage' );
like( $bad_auth->{error}, qr/auth must be true or false/, 'and the refusal names the key' );

# `tls: false` used to be listed under checked because the STRING was truthy.
for my $spelling (qw(false no off 0)) {
    conf("method: smtp\nhost: 127.0.0.1\nport: $port\ntls: $spelling\n");
    my $r = validate();
    ok( $r->{ok}, "tls: $spelling validates" ) or diag explain $r;
    ok( !( grep { $_ eq 'tls' } @{ $r->{checked} || [] } ),
        "tls: $spelling does not list tls as checked" );
}
conf("method: smtp\nhost: 127.0.0.1\nport: $port\ntls: sometimes\n");
my $bad_tls = validate();
is( $bad_tls->{stage}, 'config', 'tls: sometimes is refused at the config stage' );
like( $bad_tls->{error}, qr/tls must be/, 'and the refusal names the key' );

kill 'TERM', $pid;
waitpid $pid, 0;

done_testing();
