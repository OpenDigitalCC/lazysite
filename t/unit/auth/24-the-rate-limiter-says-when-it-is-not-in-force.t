#!/usr/bin/perl
# SM798, from the wild-facing review: check_login_rate fails OPEN when it
# cannot run - a missing DB_File, or a counter it cannot open - and did so in
# complete silence. So a site with no login rate limiting looked exactly like a
# site with login rate limiting, from every surface including its own health
# report.
#
# That is SM784's collapse in an authorisation gate: "I could not check"
# answered as "under the cap".
#
# THE DIRECTION IS NOT CHANGED, and that is the decision this test also
# records. Failing closed would refuse every login on a host missing an
# optional module - locking an operator out of their own site to enforce a rate
# limit is a worse failure than not enforcing it. What changes is that the log
# now carries what was actually established.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);

my $src = do {
    open my $fh, '<', repo_root() . '/lazysite-auth.pl' or die $!;
    local $/;
    <$fh>;
};
my ($sub) = $src =~ /(sub check_login_rate \{.*?\n\})/s;
ok( $sub, 'check_login_rate was found' ) or do { done_testing; exit };

subtest 'it still fails open' => sub {
    my @returns = $sub =~ /return 1;\s*#\s*fail open/g;
    cmp_ok( scalar @returns, '>=', 2,
        'both unrunnable cases still allow the login' )
        or diag( 'Failing closed here locks an operator out of their own site '
            . 'when an optional module is missing.' );
};

subtest 'and it says so, naming which of the two happened' => sub {
    my @warns = $sub =~ /log_event\( 'WARN'/g;
    is( scalar @warns, 2, 'each unrunnable case logs' );

    like( $sub, qr/DB_File is not installed/,
        'the missing-module case names the module' );
    like( $sub, qr/libdb-file-perl/,
        'and the package that supplies it - a WARN an operator can act on' );
    # The sentence is split across a Perl concatenation, so this matches the
    # contiguous half rather than the rendered text.
    like( $sub, qr/its counter could not be/,
        'the unopenable-counter case says that instead' );
    like( $sub, qr/file => \$LOGIN_RATE_DB/, 'naming the file' );
    like( $sub, qr/error => \$why/,          'and the error' );

    # The sentence that matters: not "a warning", but what is now untrue of
    # the site.
    my @claims = $sub =~ /(rate limiter is NOT in force)/g;
    is( scalar @claims, 2,
        'both say the limiter is NOT IN FORCE, rather than merely reporting a '
            . 'fault - the operator needs the consequence, not the cause alone' );
};

done_testing;
