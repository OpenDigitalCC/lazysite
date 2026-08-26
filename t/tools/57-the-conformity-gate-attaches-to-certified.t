#!/usr/bin/perl
# ADR 0010: the conformity gates moved from stable to certified - and this
# proves the MOVE, not just the destination.
#
# The dangerous regression is asymmetric. If certified forgot to block, the
# certified channel would be a label (the SM377 class). If stable KEPT
# blocking, the whole point of the split - stable ships supported software
# without being hostage to paperwork on its own timeline - silently fails, and
# nobody notices until a stable cut refuses in the release manager's hands.
# So both directions are asserted, against the tool's real records in this
# tree: the declaration is genuinely an unsigned 0.8.0 placeholder and the
# restore rehearsal genuinely predates the last stable cut, which is exactly
# the state these gates exist to catch.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root = repo_root();
my $tool = "$root/tools/lazysite-compliance.pl";
plan skip_all => "no $tool" unless -f $tool;
my $switch = "$root/docs/compliance/SIGNOFF.md";
plan skip_all => 'no SIGNOFF.md' unless -f $switch;

# Same backup/restore idiom as t/tools/52, and for the same reason: the switch
# is a real file the tool really reads, so the test sets it rather than mocking.
my $sbak = "/tmp/lazysite-cert-switch-$$";
my $orig = do { open my $fh, '<', $switch or die $!; local $/; <$fh> };
open my $b, '>', $sbak or die $!; print {$b} $orig; close $b;
END {
    if ( defined $sbak && -f $sbak ) {
        open my $r, '<', $sbak or die $!;
        local $/;
        my $t = <$r>;
        close $r;
        open my $w, '>', $switch or die $!;
        print {$w} $t;
        close $w;
        unlink $sbak;
    }
}

# SM603: THE REHEARSAL RECORD IS A FIXTURE NOW, not ambient state.
#
# The certified subtest needs a STALE rehearsal to prove the finding is a hard
# FAIL there. It used to get one by the repo happening to be behind - so the
# moment a rehearsal was recorded, as the 0.11.0 stable prep did, the test that
# checks staleness is caught failed because nothing was stale. A test that
# needs the project to be broken cannot be run on a healthy project.
#
# Same pattern set_switch already uses: mutate, measure, restore. The END block
# below restores both, so a die mid-test cannot leave the record edited.
my $reliab = "$root/docs/RELIABILITY.md";
my $reliab_orig = do { open my $fh, '<', $reliab or die $!; local $/; <$fh> };

sub age_rehearsals {
    ( my $t = $reliab_orig ) =~ s/^(\s*)20\d\d-\d\d-\d\d(\s*\|)/${1}2001-01-01${2}/mg;
    open my $fh, '>', $reliab or die $!;
    print {$fh} $t;
    close $fh;
    return;
}

sub restore_rehearsals {
    open my $fh, '>', $reliab or die $!;
    print {$fh} $reliab_orig;
    close $fh;
    return;
}

END { restore_rehearsals() if defined $reliab_orig }

sub set_switch {
    my ($value) = @_;
    ( my $t = $orig ) =~ s/^signoff_required:.*$/signoff_required: $value/m;
    open my $fh, '>', $switch or die $!;
    print {$fh} $t;
    close $fh;
    return;
}

sub run_check {
    my ($channel) = @_;
    my $out = `cd \Q$root\E && perl \Q$tool\E --check --channel \Q$channel\E 2>&1`;
    return ( $? >> 8, $out );
}

subtest 'a stable cut passes under the documented protocol - the gate MOVED' => sub {
    # SIGNOFF.md's protocol: the switch stays 'no' until a cut claims
    # certification. Before ADR 0010, this exact configuration still BLOCKED a
    # stable cut - the restore-rehearsal check was a hard gate at stable,
    # switch or no switch. Passing now is the move, measured.
    set_switch('no');
    my ( $rc, $out ) = run_check('stable');
    is( $rc, 0, 'a stable cut passes with the switch at no' ) or diag($out);
    like( $out, qr/blocking at a certified cut/,
        'the declaration finding is an advisory pointing one rung up' );
    # SM603: ONLY WHEN THE FINDING IS THERE. This asserted the restore-rehearsal
    # warning's text unconditionally, which pinned a TRANSIENT STATE: the
    # warning exists only while the rehearsal record is stale, so recording a
    # rehearsal - the very thing the finding asks for - failed the test that
    # checks the finding is advisory. A check whose evidence disappears when
    # the problem is fixed cannot tell "fixed" from "broken".
    #
    # The property is: IF the rehearsal finding appears at stable, it points one
    # rung up rather than blocking. When the cadence is met there is no finding
    # and nothing to point anywhere, which is the stronger outcome.
    if ( $out =~ /restore rehearsal:/ ) {
        like( $out, qr/blocking at certified/,
            'and so is the restore-rehearsal finding' );
    }
    else {
        like( $out, qr/newest restore rehearsal/,
            'the rehearsal cadence is met, so there is no finding to be advisory' );
    }
};

subtest 'the switch keeps its voluntary meaning below certified' => sub {
    # An operator may still demand the records on any cut. ADR 0010 moved the
    # channel that FORCES them; it did not weaken the switch.
    set_switch('yes');
    my ( $rc, $out ) = run_check('stable');
    isnt( $rc, 0, 'stable with signoff_required: yes still blocks' );
    like( $out, qr/reviewed_at_version|covers_version/,
        'on the person-only records, as before' );
};

subtest 'certified is where the records bite, and the switch cannot mask them' => sub {
    # The channel IS the statement that the records were walked. A certified
    # cut with the switch left at 'no' must not sail through on masked
    # findings - that would be a certified label over unwalked records.
    set_switch('no');
    age_rehearsals();    # SM603: construct the staleness rather than depend on it
    my ( $rc, $out ) = run_check('certified');
    isnt( $rc, 0, 'a certified cut refuses on this tree despite the switch' );
    like( $out, qr/signoff_required forced on/,
        'and says the channel forced the switch' );
    like( $out, qr/declaration of conformity/i, 'naming the declaration' );
    like( $out, qr/^\s*FAIL .*restore rehearsal/mi,
        'and the restore rehearsal - as a FAIL line, not merely mentioned: '
            . 'a sabotage that demoted it to advisory left its TEXT in the '
            . 'output and the first version of this assertion passed' );
    unlike( $out, qr/^\s*MASKED .*declaration/mi,
        'the declaration is NOT masked at certified' );
};

done_testing();
