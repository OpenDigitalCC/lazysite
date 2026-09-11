#!/usr/bin/perl
# SM798: the login rate limiter is a switchable extension, on by default.
#
# RULED 2026-09-10 (switchable, DB_File the extension's dependency) and
# 2026-09-11 (on by default: the installer lists it). OFF means nothing is
# counted and no counter is kept - and it is visibly off: the sign-in CGI logs
# that the limiter is NOT in force, in the same words as a limiter that cannot
# run, so "switched off on purpose" and "broken quietly" never look alike.
#
# Driven through the real CGI, as t/unit/auth/03 is. Reproduced before the
# change: with the extension absent from the registry the sixth attempt was
# still refused, and a counter was created.
use strict;
use warnings;
use Test::More;
use DB_File;
use Fcntl qw(O_RDWR O_CREAT);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root env_passthrough site_tempdir);

my $root   = repo_root();
my $WINDOW = 300;
my $ip     = '10.99.88.78';

sub site {
    my ($conf_extra) = @_;
    my $d = site_tempdir();
    mkdir "$d/lazysite";
    mkdir "$d/lazysite/auth";
    open my $uf, '>', "$d/lazysite/auth/users" or die $!;
    print {$uf} "alice:dummy-not-a-real-hash\n";
    close $uf;
    open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
    print {$cf} "site_name: R\nauth_redirect: /login\n$conf_extra";
    close $cf;
    return $d;
}

sub seed_max {
    my ($d) = @_;
    my $into = time() % $WINDOW;
    sleep( $WINDOW - $into + 1 ) if $into > $WINDOW - 8;
    my %db;
    tie %db, 'DB_File', "$d/lazysite/auth/.login-rate.db", O_CREAT | O_RDWR, 0o600 or die "tie: $!";
    $db{ "$ip:" . int( time() / $WINDOW ) } = 5;
    untie %db;
    return;
}

sub login_once {
    my ($d)  = @_;
    my $body = 'username=alice&password=wrong&next=/';
    my $err  = "$d/../stderr.log";
    local %ENV = (
        env_passthrough(),
        DOCUMENT_ROOT  => $d,
        REQUEST_METHOD => 'POST',
        QUERY_STRING   => 'action=login',
        CONTENT_LENGTH => length($body),
        REMOTE_ADDR    => $ip,
    );
    require IPC::Open2;
    open my $save, '>&', \*STDERR or die $!;
    open STDERR,   '>',  $err     or die $!;
    my ( $cout, $cin );
    my $pid = IPC::Open2::open2( $cout, $cin, $^X, "$root/lazysite-auth.pl" );
    open STDERR, '>&', $save or die $!;
    print {$cin} $body;
    close $cin;
    my $out = do { local $/; <$cout> };
    close $cout;
    waitpid $pid, 0;
    my $log = do { open my $fh, '<', $err or die $!; local $/; <$fh> };
    return ( $out, $log );
}

subtest 'listed in the registry, it counts and refuses the sixth attempt' => sub {
    my $d = site("plugins:\n  - plugins/login-rate-limit.pl\n");
    seed_max($d);
    my ( $out, $log ) = login_once($d);
    like( $out, qr{Location:[^\n]*error=rate}, 'the sixth attempt is rate-limited' ) or diag $log;
};

subtest 'switched off, nothing is counted and it says the limiter is not in force' => sub {
    my $d = site('');
    seed_max($d);
    my ( $out, $log ) = login_once($d);
    like( $out, qr{Location:[^\n]*error=1}, 'the attempt reaches the credential check' );
    unlike( $out, qr{error=rate}, 'and is not rate-limited' );
    like( $log, qr/login rate limiter is NOT in force: the login rate limit extension is switched off/,
        'the log says the limiter is not in force, and why' );

    my $fresh = site('');
    login_once($fresh);
    ok( !-e "$fresh/lazysite/auth/.login-rate.db", 'and no counter is created' );
};

done_testing();
