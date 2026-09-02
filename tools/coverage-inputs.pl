#!/usr/bin/perl
# tools/coverage-inputs.pl - the digest of everything that decides coverage.
#
# SM736: the coverage stage is the most expensive thing this project runs - two
# hours and twenty minutes on the 0.11.11 cut, against eleven minutes for the
# whole correctness suite. It is also a PURE FUNCTION of a knowable input set:
# the measured CGIs, the library they call into, every test that exercises them,
# and the floor config. Nothing else can move the percentage.
#
# So when that set is byte-identical to a run that already passed, the answer is
# known and re-deriving it buys nothing.
#
# WHAT THIS DELIBERATELY DOES NOT COVER. The correctness suite is not skippable
# on this argument and is not skipped: a gate result is a fact about a tree AT A
# TIME, and date-sensitive tests exist as a class - the 0.11.0 work found five
# stats tests that failed daily for ninety minutes after UTC midnight. Coverage
# is a structural measurement and does not have that property; correctness does.
#
# WHERE IT ACTUALLY FIRES: a promotion. Two different releases always differ
# somewhere in lib/ or t/, so the digest changes and the stage runs. A stable cut
# from the same commit as the beta that passed differs only in the version stamp,
# which is not in this set - so it matches, and the stage is skipped.
use strict;
use warnings;
use Digest::SHA qw(sha256_hex);
use File::Find;
use File::Basename qw(dirname);
use Cwd            qw(abs_path);

my $ROOT = dirname( dirname( abs_path($0) ) );
chdir $ROOT or die "coverage-inputs.pl: $ROOT: $!\n";

# The eight gated CGIs, named here because coverage.sh names them too - if the
# two ever disagree this digest would attest a set that is not the measured one.
# t/lint/111 asserts they match.
my @EXPLICIT = qw(
    lazysite-dav.pl lazysite-processor.pl lazysite-manager-api.pl
    lazysite-auth.pl lazysite-mcp.pl lazysite-oauth.pl
    tools/lazysite-users.pl tools/lazysite-bundle-apply.pl
    dist/config/coverage-floor
);

my @files = grep { -f } @EXPLICIT;

# Every test, because a test added or removed changes which lines run; and
# every library module, because the CGIs call into them.
for my $dir (qw(t lib)) {
    next unless -d $dir;
    find(
        { no_chdir => 1,
            wanted => sub {
                return unless -f $File::Find::name;
                push @files, $File::Find::name
                    if $File::Find::name =~ /\.(?:t|pm|pl)$/;
            },
        },
        $dir
    );
}

my $h = Digest::SHA->new(256);
for my $f ( sort @files ) {
    open my $fh, '<:raw', $f or next;
    local $/;
    $h->add( $f, <$fh> );
    close $fh;
}
printf "%s %d\n", $h->hexdigest, scalar @files;
