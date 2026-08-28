#!/usr/bin/perl
# SM501: the render timestamp is valid for two hours, fixed, while rate_limit is
# per-form configurable.
#
# The reporter's case: a long careful form crosses two hours as the ORDINARY
# case, and the refusal lands after the typing - the worst possible moment. They
# worked around it with partial submission and shorter pages and asked for no
# exemption; this filing existed so the second report would find the first.
#
# WHAT THIS MUST NOT DO is weaken the check into a decoration. `off` disables
# the AGE CEILING only: the HMAC still has to match, so a timestamp cannot be
# forged or lifted from another form, and the too-fast floor still applies. A
# test that only proved "a wide window accepts an old submission" would pass
# just as well against a check that had been deleted, so the forged and
# too-fast cases are asserted in the same run.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);
use Digest::SHA qw(hmac_sha256_hex);

my $root = repo_root();
my $fh_p = "$root/plugins/form-handler.pl";
plan skip_all => 'form handler missing' unless -f $fh_p;

my $src = do { open my $f, '<', $fh_p or die $!; local $/; <$f> };

# The check, lifted and compiled - not reimplemented. A local copy would pass
# with the shipped one deleted.
my ($sub) = $src =~ /(sub check_timestamp \{.*?\n\})/s;
ok( $sub, 'check_timestamp was extracted' ) or BAIL_OUT('nothing to test');

our @rejected;    # package, not lexical - see below
my $pkg = q{
    package SM501Probe;
    use Digest::SHA qw(hmac_sha256_hex);
    sub reject { push @main::rejected, $_[0]; die "rejected\n" }
} . $sub;
# NOTE: reject() above pushes to @main::rejected. Declaring `my @rejected` here
# instead creates a DIFFERENT array that never receives anything, so every call
# appears to be accepted and the permissive assertions pass while the refusals
# fail. That is what the first run of this file did.
eval "$pkg 1" or BAIL_OUT("could not compile check_timestamp: $@");

my $SECRET = 'a-test-secret';
sub try {
    my ( $age, $window ) = @_;
    @rejected = ();
    my $ts = time() - $age;
    my $tk = hmac_sha256_hex( $ts, $SECRET );
    eval { SM501Probe::check_timestamp( $ts, $tk, $SECRET, $window ) };
    return $rejected[0] // '';
}

subtest 'the default is unchanged' => sub {
    is( try( 60, undef ), '', 'a fresh submission is accepted' );
    is( try( 7300, undef ), 'Submission expired',
        'and one older than two hours is refused, as before' )
        or diag( 'The shipped default must not move for a form that says '
            . 'nothing - every existing form relies on it.' );
};

subtest 'a form can widen its own window' => sub {
    is( try( 7300, 86400 ), '', 'an old submission is accepted with a day-long window' );
    is( try( 90000, 86400 ), 'Submission expired',
        'and one past the widened window is still refused' )
        or diag( 'A window that accepts everything is not a window.' );
};

subtest 'off disables the age ceiling and nothing else' => sub {
    is( try( 999999, 0 ), '', 'a very old submission is accepted when off' );

    # The two protections that must survive `off`.
    @rejected = ();
    my $ts = time() - 999999;
    eval { SM501Probe::check_timestamp( $ts, 'not-the-hmac', $SECRET, 0 ) };
    is( $rejected[0] // '', 'Invalid submission',
        'a forged token is still refused with the ceiling off' )
        or diag( 'If off skipped the HMAC this would be a replay hole, not a '
            . 'usability setting.' );

    is( try( 1, 0 ), 'Submission too fast',
        'and the too-fast floor still applies' );
};

done_testing();
