#!/usr/bin/perl
# SM798: the health check says when the login rate limiter is not in force.
#
# The limiter fails open - a missing DB_File, or a counter the sign-in CGI
# cannot open, lets every attempt through - and since 0.13.10 it says so in the
# log on each attempt. The filing recorded what that left: `lazysite check` is
# where an operator looks for this kind of fact, and it said nothing, so a site
# with no login rate limiting read as healthy on the one surface built to say
# otherwise.
#
# Reproduced before the fix: none of the lines below was printed.
use strict;
use warnings;
use Test::More;
use File::Basename ();
use File::Path     qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root site_tempdir);

my $root   = repo_root();
my $script = "$root/tools/lazysite-check.pl";

# Switched on, as the installer leaves every site (SM798: an extension, on by
# default); site(0) is one an operator switched off.
sub site {
    my ($on) = @_;
    $on //= 1;
    my $doc  = site_tempdir();
    my $base = File::Basename::dirname($doc);
    make_path("$doc/lazysite/$_") for qw(auth cache logs manager);
    open my $cf, '>', "$doc/lazysite/lazysite.conf" or die $!;
    print {$cf} "site_name: T\n" . ( $on ? "plugins:\n  - plugins/login-rate-limit.pl\n" : '' );
    close $cf;
    return ( $base, $doc );
}

sub check {
    my ( $doc, %env ) = @_;
    local @ENV{ keys %env } = values %env;
    return scalar qx($^X \Q$script\E --docroot \Q$doc\E 2>&1);
}

plan skip_all => 'DB_File is not installed here' unless eval { require DB_File; 1 };

subtest 'a working limiter says it is in force' => sub {
    my ( undef, $doc ) = site();
    like( check($doc), qr/login rate limiter is in force/, 'said, so its absence means something' );
};

subtest 'switched off, it says so in the same words, with the reason' => sub {
    my ( undef, $doc ) = site(0);
    my $out = check($doc);
    like( $out, qr/login rate limiter is NOT in force: the login rate limit extension is\s+switched off/,
        'reported as not in force, because it is switched off' )
        or diag $out;
    unlike( $out, qr/login rate limiter is in force/, 'and never as in force' );
};

subtest 'without DB_File it says the limiter is NOT in force, and what to install' => sub {
    my ( $base, $doc ) = site();

    # DB_File hidden the way a host without it answers: require fails.
    make_path("$base/hide");
    open my $h, '>', "$base/hide/DB_File.pm" or die $!;
    print {$h} "die \"Can't locate DB_File.pm in \\\@INC (hidden by the test)\\n\";\n";
    close $h;
    my $out = check( $doc, PERL5LIB => "$base/hide" . ( length( $ENV{PERL5LIB} // '' ) ? ":$ENV{PERL5LIB}" : '' ) );
    like( $out, qr/login rate limiter is NOT in force/, 'reported' ) or diag $out;
    like( $out, qr/libdb-file-perl/, 'naming the package that supplies it' );
};

subtest 'a counter the sign-in CGI cannot open says the same' => sub {
    my ( undef, $doc ) = site();
    my $db = "$doc/lazysite/auth/.login-rate.db";
    open my $fh, '>', $db or die $!;
    close $fh;
    chmod 0000, $db or die $!;
    my $out = check($doc);
    like( $out, qr/login rate limiter is NOT in force/, 'reported' ) or diag $out;
    like( $out, qr/\.login-rate\.db/,                   'naming the file' );
    chmod 0600, $db;
};

done_testing();
