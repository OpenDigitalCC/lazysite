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

# The digest of this tree, from the tool the script itself uses.
my $digest = `$^X \Q$inp\E 2>/dev/null`;
($digest) = ( $digest // '' ) =~ /\A(\S+)/;
plan skip_all => 'no digest available' unless defined $digest && length $digest;

my $dir = tempdir( CLEANUP => 1 );

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
sub decision {
    my ($record) = @_;
    my $out
        = `LAZYSITE_COVER_RECORD=\Q$record\E LAZYSITE_COVER_DECIDE_ONLY=1 bash \Q$cov\E 2>&1`;
    return $out // '';
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
    my $out
        = `LAZYSITE_COVER_FORCE=1 LAZYSITE_COVER_RECORD=\Q$rec\E LAZYSITE_COVER_DECIDE_ONLY=1 bash \Q$cov\E 2>&1`;
    unlike( $out // '', qr/coverage: SKIPPED/,
        'an operator who says measure it anyway is obeyed' );
};

done_testing();
