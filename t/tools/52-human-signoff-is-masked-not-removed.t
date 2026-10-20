#!/usr/bin/perl
# SM352/SM375: findings only a person can close are MASKED, not deleted.
#
# Walking the obligations register, re-reading the technical file and signing a
# declaration of conformity cannot be done by a commit. Until 2026-08-18 they
# blocked a release outright, which sounds stricter and was not: the version
# they compared against had itself been stale for five releases (SM375), so the
# gate had been passing on a false premise the whole time. A gate that blocks on
# a question it is asking wrongly teaches people to work around it.
#
# THE PROPERTY UNDER TEST IS THAT NOTHING IS HIDDEN. A masked finding is printed
# in full and counted; flipping the switch reveals no new information. If that
# ever stops being true this becomes a way to make a gate quiet, which is the
# opposite of what it is for.
#
# AND ABSENT MUST MEAN REQUIRED. Deleting the switch must not disable the gate -
# the same fail-closed rule as the update channel, which SM356 found failing
# OPEN, where a typo granted rather than refused.
use strict;
use warnings;
use Test::More;
use File::Copy     qw(move copy);
use File::Path     qw(make_path);
use File::Basename qw(dirname);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root site_tempdir);

my $repo = repo_root();
plan skip_all => "no $repo/tools/lazysite-compliance.pl"
    unless -f "$repo/tools/lazysite-compliance.pl";
plan skip_all => 'no SIGNOFF.md'
    unless -f "$repo/docs/compliance/SIGNOFF.md";

# SM1210: THIS TEST NEVER WRITES THE CHECKOUT. Until then it wrote 99.0.0 into
# the tracked VERSION (and edited SIGNOFF.md) for the length of its run, behind
# preserve_tracked's lock. Every test that reads VERSION without that lock
# could see 99.0.0 when run beside it under prove -j. The tool takes its root
# from its own location (dirname of FindBin::Bin), so a scratch tree holding a
# copy of the tool and of the few files it reads is a real run of the same code
# with nothing shared.
my $scratch = dirname( site_tempdir() );                 # a scratch tree, removed at exit
my $tool    = "$scratch/tools/lazysite-compliance.pl";
my $switch  = "$scratch/docs/compliance/SIGNOFF.md";

my @needs = (
    'tools/lazysite-compliance.pl',
    'CHANGELOG.md',
    'docs/releases/CHANGELOG-archive.md',
    'docs/DECLARATION-OF-CONFORMITY.md',
    'docs/SECURITY.md',
    'docs/FEATURES.md',
    'docs/RELIABILITY.md',
    'dist/config/bench-baseline.json',
    'docs/compliance/OBLIGATIONS.md',
    'docs/compliance/TECHNICAL-FILE.md',
    'docs/compliance/SIGNOFF.md',
);
for my $rel (@needs) {
    next unless -f "$repo/$rel";
    make_path( dirname("$scratch/$rel") );
    copy( "$repo/$rel", "$scratch/$rel" ) or die "copy $rel: $!";
}

# The findings only appear when a record is BEHIND the version being cut, so the
# fixture forces that rather than depending on whatever today's VERSION says -
# a test that only works while the tree happens to be stale would pass by
# accident and stop testing the moment somebody walked the registers.
my $vf = "$scratch/VERSION";

sub read_file {
    my ($path) = @_;
    open my $fh, '<', $path or die "$path: $!";
    local $/;
    return <$fh>;
}

sub write_file {
    my ( $path, $body ) = @_;
    open my $fh, '>', $path or die "$path: $!";
    print {$fh} $body;
    close $fh;
    return;
}

sub set_switch {
    my ($value) = @_;
    my $text = read_file($switch);
    $text =~ s/^signoff_required:.*$/signoff_required: $value/m;
    write_file( $switch, $text );
    return;
}

sub run_check {
    my $out = `cd \Q$scratch\E && perl \Q$tool\E --check --channel edge 2>&1`;
    return ( $? >> 8, $out );
}

# A version far ahead of anything the records claim.
write_file( $vf, "99.0.0\n" );

subtest 'masked: reported in full, and not blocking' => sub {
    set_switch('no');
    my ( $rc, $out ) = run_check();
    is( $rc, 0, 'the gate does not block' );
    like( $out, qr/^\s*MASKED .*reviewed_at_version/m,
        'the obligations finding is printed, labelled MASKED' );
    like( $out, qr/^\s*MASKED .*covers_version/m,
        'and so is the technical file finding' );
    like( $out, qr/\d+ masked/, 'the count is on the summary line' );
    like( $out, qr/SIGNOFF\.md/,
        'and the output names the file the decision lives in' )
        or diag( 'A masked count with no explanation is worse than the '
            . 'finding it covers - a reader cannot tell whether a decision '
            . 'was made or a gate broke.' );
};

subtest 'required: the same findings block' => sub {
    set_switch('yes');
    my ( $rc, $out ) = run_check();
    isnt( $rc, 0, 'the gate blocks' );
    like( $out, qr/^\s*FAIL .*reviewed_at_version/m, 'as a FAIL' );
    like( $out, qr/0 masked/,                        'and nothing is masked' );
};

subtest 'absent: treated as required, so deleting it disables nothing' => sub {
    move( $switch, "$switch.gone" ) or die $!;
    my ( $rc, $out ) = run_check();
    move( "$switch.gone", $switch ) or die $!;
    isnt( $rc, 0, 'a missing switch blocks' )
        or diag( 'Fail-open here would mean the gate could be disabled by '
            . 'deleting a file, which is how SM356 granted access on a typo.' );
    like( $out, qr/^\s*FAIL /m, 'the findings are still findings' );
};

subtest 'the same findings appear either way' => sub {
    set_switch('no');
    my ( undef, $off ) = run_check();
    set_switch('yes');
    my ( undef, $on ) = run_check();

    for my $t ( $off, $on ) {
        $t =~ s/^\s*(?:MASKED|FAIL) //mg;
        $t =~ s/^\d+ ok.*$//m;
        $t =~ s/^Masked findings.*\z//ms;
        $t =~ s/^Blocking\..*\z//ms;
    }
    is( $off, $on,
        'masking changes the verdict and not the findings' )
        or diag( 'If flipping the switch reveals something new, then masking '
            . 'is hiding rather than deferring, and this stops being a '
            . 'decision the release manager can make honestly.' );
};

done_testing();
