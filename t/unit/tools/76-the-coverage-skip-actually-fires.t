#!/usr/bin/perl
# SM736: the skip fires on a matching digest, and refuses on everything else.
#
# The mechanism shipped in 0.11.12 and its skip HAD NEVER RUN. Not because it
# was wrong - three release cuts have exercised the surrounding machinery and
# the record now survives the build that writes it - but because a skip needs
# two consecutive builds whose inputs are byte-identical, and every cut so far
# has changed something. So the one branch the feature exists for was
# unexercised in the field and unexercised by any test, which is the state
# SM732 was in when it turned out to have no caller at all.
#
# It could not be tested before, and that was the real defect: COVER_RECORD was
# hard-coded, so proving the skip meant planting a matching record in the
# repository - and a test killed between planting and restoring would leave a
# record that makes a REAL release skip its coverage gate. Risking that in
# order to test a shortcut is a bad trade, so the path is now overridable and
# this points it at a temporary file.
#
# THE REFUSALS MATTER MORE THAN THE SKIP. "Absence refuses" is the property
# that makes the shortcut safe: no record, an unreadable one, a different
# digest, or a RECORDED FAILURE all mean the stage runs. A skip that fired on
# any of those would silently drop the coverage gate from a release.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);

my $root = repo_root();
my $cov  = "$root/tools/coverage.sh";
my $inp  = "$root/tools/coverage-inputs.pl";

plan skip_all => 'no coverage tooling' unless -f $cov && -f $inp;

my $dir = tempdir( CLEANUP => 1 );

# THE DIGEST IS ASKED OF THE SCRIPT, not computed alongside it.
#
# The first version ran tools/coverage-inputs.pl itself and planted the answer,
# assuming coverage.sh would compute the same thing. That assumption FAILED A
# RELEASE: under the instrumented suite the two disagreed, the skip did not
# fire, and subtest 1 failed - while passing standalone every time. I could not
# reproduce it afterwards either, which is the point: the digest covers every
# .t, .pm and .pl under t/ and lib/, and a full parallel suite is not a quiet
# tree to take a fingerprint of.
#
# So the equality is not assumed. DECIDE_ONLY prints the digest the script
# actually saw, and that is what gets planted - which tests the same property
# (a matching record on a pass skips) without depending on two independent
# walks of a moving tree agreeing.
my $probe = run_coverage( record => "$dir/nothing-here.json" );
my ($digest) = $probe =~ /digest\s+(\S+)/;
plan skip_all => 'coverage.sh reported no digest' unless defined $digest;


sub write_record {
    my ($json) = @_;
    my $f = "$dir/record.json";
    open my $fh, '>', $f or die $!;
    print {$fh} $json;
    close $fh;
    return $f;
}

# Run coverage.sh with the record pointed somewhere harmless, in DECIDE-ONLY
# mode so that a must-not-skip case never starts an instrumented suite.
#
# The first version let them start and killed each after eight seconds. That
# wasted a minute, and worse, it left a cover_db-suite.log in the working tree -
# which duly got committed. A test that dirties the repository to prove a
# shortcut is safe has traded one hazard for another.
# PERL5OPT IS CLEARED, and this file failed a release by not doing it.
#
# This test runs coverage.sh from inside the suite, and the suite sometimes
# runs UNDER coverage.sh. Inherited, the outer run's Devel::Cover follows every
# process this one starts - so the digest the inner script computed did not
# match the one this test had computed, the skip did not fire, and subtest 1
# failed. It passed standalone every time.
#
# t/tools/60 had already met this, solved it the same way, and written down the
# rule: A HARNESS THAT TESTS A HARNESS HAS TO STAND OUTSIDE THE ONE IT IS
# TESTING. I wrote a second one without reading the first.
sub run_coverage {
    my (%a) = @_;
    local $ENV{PERL5OPT}                   = '';
    local $ENV{HARNESS_PERL_SWITCHES}      = '';
    local $ENV{LAZYSITE_COVER_RECORD}      = $a{record};
    local $ENV{LAZYSITE_COVER_DECIDE_ONLY} = 1;
    local $ENV{LAZYSITE_COVER_FORCE}       = $a{force} ? 1 : '';
    my $out = qx(bash \Q$cov\E 2>&1);
    return $out // '';
}

sub decision {
    my ($record) = @_;
    return run_coverage( record => $record );
}

subtest 'a matching digest on a PASSING run skips' => sub {
    my $rec = write_record(
        qq({"inputs_digest":"$digest","result":"pass","floor":"75"}));
    my $out = decision($rec);

    like( $out, qr/coverage: SKIPPED/,
        'the skip fires - the branch this feature exists for, run at last' )
        or diag($out);
    like( $out, qr/\Q$digest\E/, 'and it names the digest it matched' );
    like( $out, qr/LAZYSITE_COVER_FORCE=1/,
        'and says how to override, because a skip an operator cannot undo is a trap' );
};

subtest 'a RECORDED FAILURE never licenses a skip' => sub {
    # The most dangerous of the refusals: the digest matches, so a naive check
    # would skip - and the run it matches FAILED. That would drop the coverage
    # gate from a release on the strength of a failure.
    my $rec = write_record(
        qq({"inputs_digest":"$digest","result":"fail","floor":"75"}));
    unlike( decision($rec), qr/coverage: SKIPPED/,
        'a matching digest on a FAILED run runs the stage' );
};

subtest 'a different digest runs the stage' => sub {
    my $rec = write_record(
        qq({"inputs_digest":"0000000000000000","result":"pass","floor":"75"}));
    unlike( decision($rec), qr/coverage: SKIPPED/,
        'inputs that changed are measured again' );
};

subtest 'an unreadable or absent record runs the stage' => sub {
    my $bad = write_record('this is not json {');
    unlike( decision($bad), qr/coverage: SKIPPED/,
        'a corrupt record refuses rather than being interpreted generously' );

    unlike( decision("$dir/no-such-file.json"), qr/coverage: SKIPPED/,
        'and an absent one refuses too - absence is not permission' );
};

subtest 'FORCE overrides a legitimate skip' => sub {
    my $rec = write_record(
        qq({"inputs_digest":"$digest","result":"pass","floor":"75"}));
    my $out = run_coverage( record => $rec, force => 1 );
    unlike( $out // '', qr/coverage: SKIPPED/,
        'an operator who says measure it anyway is obeyed' );
};

done_testing();
