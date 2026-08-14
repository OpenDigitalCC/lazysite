package FlakeLog;
# Cumulative record of intermittent test outcomes.
#
# WHY THIS EXISTS. t/tools/03-install-pl.t failed once inside a combined
# lint+tools run and passed standalone and on the two runs after it. The honest
# report at the time was "I saw it fail once and could not reproduce it", which
# is worth almost nothing: it is a single anecdote, it decays out of memory, and
# the next person to see it also writes it down and also cannot act.
#
# One observation is an anecdote. Fifty observations with a failure rate is a
# defect with a size. This module turns the first into the second by recording
# every outcome to an append-only log, so an intermittent failure accumulates
# evidence instead of being re-noticed.
#
# It records rather than judges. A test using it still passes or fails on its
# own assertions; nothing here changes a verdict. The log is for the human
# deciding whether a 1-in-40 failure is worth chasing.
#
# Off by default. Set LAZYSITE_FLAKE_LOG=1 (the release gate does) or point
# LAZYSITE_FLAKE_LOG_FILE at a path. A test suite that writes files nobody asked
# for is its own kind of rude.
use strict;
use warnings;
use Exporter qw(import);
our @EXPORT_OK = qw(record_outcome flake_log_path summarise);

sub flake_log_path {
    return $ENV{LAZYSITE_FLAKE_LOG_FILE} if $ENV{LAZYSITE_FLAKE_LOG_FILE};
    return undef unless $ENV{LAZYSITE_FLAKE_LOG};
    my $dir = $ENV{TMPDIR} || '/tmp';
    return "$dir/lazysite-flake.jsonl";
}

# record_outcome( name => 't/tools/03', ok => 0|1, detail => '...' )
#
# One JSON line per observation. Append-only and O_APPEND, so concurrent test
# processes cannot interleave a partial line - which matters, because the runs
# most likely to flake are the parallel ones.
sub record_outcome {
    my (%a) = @_;
    my $path = flake_log_path();
    return 0 unless $path;

    my $name   = $a{name} // 'unknown';
    my $ok     = $a{ok} ? 1 : 0;
    my $detail = $a{detail} // '';
    $detail =~ s/["\\\n\r]/ /g;
    $detail = substr $detail, 0, 300;

    # Context, because "it fails in a full run and passes alone" is itself the
    # most useful signal and is invisible without recording it.
    my $ctx  = $ENV{HARNESS_ACTIVE} ? 'harness' : 'standalone';
    my $jobs = $ENV{HARNESS_OPTIONS} // '';

    my $line = sprintf
        '{"t":%d,"test":"%s","ok":%d,"ctx":"%s","jobs":"%s","host":"%s","detail":"%s"}' . "\n",
        time, $name, $ok, $ctx, $jobs, ( $ENV{HOSTNAME} // 'x' ), $detail;

    open my $fh, '>>', $path or return 0;
    print {$fh} $line;
    close $fh;
    return 1;
}

# Read the log back as { test => { runs, failures, rate } }. Used by the
# reporter; kept here so the format has exactly one reader and one writer.
sub summarise {
    my ($path) = @_;
    $path ||= flake_log_path();
    return {} unless $path;
    open my $fh, '<', $path or return {};
    my %by;
    while ( my $l = <$fh> ) {
        my ($test) = $l =~ /"test":"([^"]*)"/ or next;
        my ($ok)   = $l =~ /"ok":(\d)/;
        $by{$test}{runs}++;
        $by{$test}{failures}++ unless $ok;
    }
    close $fh;
    for my $t ( keys %by ) {
        $by{$t}{rate} = $by{$t}{runs}
            ? ( $by{$t}{failures} / $by{$t}{runs} )
            : 0;
    }
    return \%by;
}

1;
