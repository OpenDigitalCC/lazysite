#!/usr/bin/perl
# SM916: the bench fixture writes the timestamp the ENGINE writes.
#
# tools/bench.pl reports work_cold_log_bytes - the number of bytes the stats
# ingest reads out of a fixture of thirty days of visitor logs - and the gate
# treats a change in it as WORK, in its own words "a count is host-independent,
# so this is not a slow machine".
#
# That was true of the count and false of the fixture. bench.pl imports time()
# from Time::HiRes for its timing helper, so the $now the fixture was built from
# was a FLOAT, and every log line carried a fractional timestamp. JSON renders a
# float to as many digits as it needs, so one line was 9 bytes of timestamp on a
# second that landed exactly, and 15 on an ordinary one. The fixture is 4500
# lines that all share one $now, so they all grew together: exactly 4500 bytes
# per digit.
#
# The measured consequence, on this host: the 0.15.0 baseline recorded 519892,
# and the very commit it says it was captured at reproduces 524392 - stably,
# twice. The gate was refusing a cut over a 4500-byte difference that was one
# decimal digit of the wall clock. 27000 bytes of that fixture, 5.4%, was
# timestamp width rather than traffic.
#
# THE ENGINE HAS ALWAYS WRITTEN AN INTEGER. lazysite-processor.pl's
# _access_record builds its line as '{"t":' . time() and the processor does not
# import Time::HiRes, so `time` there is CORE::time. No real access log has ever
# held a fractional timestamp. The fixture was not only unstable, it was unlike
# the thing it stands in for - which is the part worth a gate, because a
# fixture that disagrees with its reader gives confident answers about a file
# shape that does not occur.
#
# So this pins BOTH sides of that agreement, and each would break it alone:
#   - the fixture must write an integer;
#   - the processor must not acquire a float time() later.
use strict;
use warnings;
use Test::More;
use FindBin;

my $ROOT = "$FindBin::Bin/../..";

# --- 1. the fixture writes an integer ---------------------------------------

my $bench = do {
    open my $fh, '<', "$ROOT/tools/bench.pl" or die "tools/bench.pl: $!";
    local $/;
    <$fh>;
};

like(
    $bench,
    qr/t \s* => \s* int\s*\(/x,
    'the bench access-log fixture writes t as an integer'
) or diag(
    "tools/bench.pl builds its thirty days of visitor logs with a `t` that is\n"
        . "not wrapped in int(). If \$now is a float - and it is, because this file\n"
        . "imports time() from Time::HiRes - then the fixture's SIZE depends on how\n"
        . "many digits the clock's fractional part happens to need, and\n"
        . "work_cold_log_bytes stops being a property of the code."
);

# The import that makes it necessary. If this ever goes away the int() is
# harmless, but while it is here the int() is load-bearing, and a reader
# deleting the "redundant" int() should meet this line.
like(
    $bench,
    qr/use \s+ Time::HiRes \s+ qw\( [^)]* \btime\b/x,
    'bench.pl does import a float time(), which is why the int() is needed'
);

# --- 2. the engine still writes an integer ----------------------------------

my $proc = do {
    open my $fh, '<', "$ROOT/lazysite-processor.pl" or die "lazysite-processor.pl: $!";
    local $/;
    <$fh>;
};

# Single-quoted, then quotemeta: the literal being matched contains $line, and
# \Q..\E inside a qr// does not stop Perl interpolating it first.
# Delimiter is ! rather than {}: the literal contains an unmatched brace, and
# q{} counts nested braces before it counts characters.
my $writes_bare_time = quotemeta q!my $line = '{"t":' . time()!;

like(
    $proc,
    qr/$writes_bare_time/,
    'the processor writes the access-log timestamp from a bare time()'
);

unlike(
    $proc,
    qr/use \s+ Time::HiRes \s+ qw\( [^)]* \btime\b/x,
    'the processor does NOT import a float time(), so its timestamps are integers'
) or diag(
    "lazysite-processor.pl has acquired a float time(). _access_record writes\n"
        . "'{\"t\":' . time() directly, so every visitor log line would start\n"
        . "carrying a fractional timestamp: larger logs, for no gain, and the\n"
        . "bench fixture would no longer match the engine. If this import is\n"
        . "wanted, _access_record needs its own int() first."
);

done_testing();
