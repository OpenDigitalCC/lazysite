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
use File::Copy qw(copy move);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root = repo_root();
my $tool = "$root/tools/lazysite-compliance.pl";
plan skip_all => "no $tool" unless -f $tool;

my $switch = "$root/docs/compliance/SIGNOFF.md";
plan skip_all => 'no SIGNOFF.md' unless -f $switch;

# The findings only appear when a record is BEHIND the version being cut, so the
# fixture forces that rather than depending on whatever today's VERSION says -
# a test that only works while the tree happens to be stale would pass by
# accident and stop testing the moment somebody walked the registers.
my $vf   = "$root/VERSION";
my $vbak = "/tmp/lazysite-signoff-version-$$";
my $sbak = "/tmp/lazysite-signoff-switch-$$";
copy( $vf,     $vbak ) or die $!;
copy( $switch, $sbak ) or die $!;

sub restore {
    copy( $vbak, $vf )     if -f $vbak;
    copy( $sbak, $switch ) if -f $sbak;
    unlink $vbak, $sbak;
    return;
}
END { restore() }

sub write_file {
    my ( $path, $body ) = @_;
    open my $fh, '>', $path or die "$path: $!";
    print {$fh} $body;
    close $fh;
    return;
}

sub set_switch {
    my ($value) = @_;
    my $text = do { open my $fh, '<', $sbak or die $!; local $/; <$fh> };
    $text =~ s/^signoff_required:.*$/signoff_required: $value/m;
    write_file( $switch, $text );
    return;
}

sub run_check {
    my $out = `cd \Q$root\E && perl \Q$tool\E --check --channel edge 2>&1`;
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

restore();
done_testing();
