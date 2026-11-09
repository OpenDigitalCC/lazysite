#!/usr/bin/perl
# SM798, then ruling 206 (2026-11-09, item 4 of the 0.16.9 fault survey): A
# LOGIN RATE LIMITER THAT CANNOT COUNT REFUSES EVERY SIGN-IN.
#
# check_login_rate failed OPEN when it could not run - a missing DB_File, or a
# counter it could not open - first in silence, then (SM798) with a WARN saying
# the limiter was NOT in force. SM798 kept the direction so a host missing a
# module would not lock its operator out. Ruling 206 decides the other way: a
# broken install is a fault, the engine refuses (cannot-tell), and the sysadmin
# repairs it from the command line, where `lazysite check` names it
# (t/tools/70). The sign-in page says sign-in is unavailable - the answer a
# broken session store gives (SM1024) - never "too many attempts".
#
# Driven through the real CGI, as t/unit/auth/25 is. An ABSENT counter is no
# fault: the first attempt makes it.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root env_passthrough site_tempdir run_child);

my $root = repo_root();
my $ip   = '10.99.88.24';

{
    open my $fh, '<', "$root/lazysite-auth.pl" or die $!;
    my $cgi = do { local $/; <$fh> };
    like( $cgi, qr/sub check_login_rate \{\s*my \(\$ip\) = \@_;\s*return Lazysite::Auth::LoginRate::check_login_rate\(/,
        'the sign-in CGI asks the one limiter rather than keeping its own' );
}

sub site {
    my $d = site_tempdir();
    make_path("$d/lazysite/auth");
    open my $uf, '>', "$d/lazysite/auth/users" or die $!;
    print {$uf} "alice:dummy-not-a-real-hash\n";
    close $uf;
    open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
    print {$cf} "site_name: R\nauth_redirect: /login\nextensions:\n  - extensions/login-rate-limit.pl\n";
    close $cf;
    return $d;
}

sub login_once {
    my ( $d, %env ) = @_;
    my $body = 'username=alice&password=wrong&next=/';
    my $err  = "$d/../stderr.log";
    local %ENV = (
        env_passthrough(),
        DOCUMENT_ROOT  => $d,
        REQUEST_METHOD => 'POST',
        QUERY_STRING   => 'action=login',
        CONTENT_LENGTH => length($body),
        REMOTE_ADDR    => $ip,
        %env,
    );
    open my $log_fh, '>', $err or die $!;
    my $out = run_child( [ $^X, "$root/lazysite-auth.pl" ], stdin => $body, stderr => $log_fh )->{out};
    close $log_fh;
    my $log = do { open my $fh, '<', $err or die $!; local $/; <$fh> };
    return ( $out, $log );
}

subtest 'ABSENT counter: no fault, the attempt is counted and judged' => sub {
    my $d = site();
    my ( $out, $log ) = login_once($d);
    like( $out, qr{Location:[^\n]*error=1}, 'a wrong password is a wrong password' ) or diag $log;
    ok( -e "$d/lazysite/auth/.login-rate.db", 'and the counter is made' );
};

subtest 'a counter that will not open refuses the sign-in as unavailable' => sub {
    my $d  = site();
    my $db = "$d/lazysite/auth/.login-rate.db";
    open my $fh, '>', $db or die $!;
    print {$fh} "this is not a DB_File database\n" x 64;
    close $fh;
    chmod 0660, $db;
    my ( $out, $log ) = login_once($d);
    like( $out, qr{Location:[^\n]*error=unavailable}, 'refused as unavailable' ) or diag $log;
    unlike( $out, qr{error=rate}, 'not as too many attempts' );
    like( $log, qr/sign-in refused: the login rate limiter cannot count - its counter cannot be opened/,
        'the log names the fault' );
    like( $log, qr/lazysite check --docroot names it/, 'and the check that names it' );
};

subtest 'without DB_File every sign-in is refused, naming the package' => sub {
    my $d    = site();
    my $hide = "$d/../hide";
    make_path($hide);
    open my $h, '>', "$hide/DB_File.pm" or die $!;
    print {$h} "die \"Can't locate DB_File.pm in \\\@INC (hidden by the test)\\n\";\n";
    close $h;
    my ( $out, $log ) = login_once( $d,
        PERL5LIB => $hide . ( length( $ENV{PERL5LIB} // '' ) ? ":$ENV{PERL5LIB}" : '' ) );
    like( $out, qr{Location:[^\n]*error=unavailable}, 'refused as unavailable' ) or diag $log;
    like( $log, qr/DB_File is not\s+installed \(Debian: libdb-file-perl\)/, 'the log names the package' );
};

done_testing;
