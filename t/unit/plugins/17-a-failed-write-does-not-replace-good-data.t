#!/usr/bin/perl
# SM404: `_write_json_atomic` was atomic in the rename and not in the write.
#
# It checked neither the print nor the close, then renamed. A write that ran out
# of space produced a TRUNCATED temp file, and the rename promoted it over a good
# one - while the function returned 1, so every caller believed it had saved.
#
# The processor's main page-cache writer has had checked print AND checked close
# since SM020, and a pre-beta review praised it for precisely this property. The
# three stats writers never gained it. One of them was added by SM393, days ago,
# written to match the local style - which is how a defect propagates once it is
# the house pattern.
#
# WHERE IT MATTERS MOST: the durable day files are written ONCE and never
# rewritten, because a past day is immutable. A torn day file is permanent. A
# torn cache merely rebuilds, slowly.
#
# DRIVEN, NOT READ. A full disk is simulated with a tiny filesystem-backed file
# via a small quota: the write really fails, and the test asserts on what is left
# on disk afterwards. Asserting that the source contains `or return 0` would pass
# against a checked print with an unchecked close, which is the case that
# actually bites - a buffered write succeeds at print and fails at the flush.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use JSON::PP   qw(decode_json);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);

my $plugin = repo_root() . '/plugins/stats.pl';
plan skip_all => "no $plugin" unless -f $plugin;

my $src      = do { open my $fh, '<', $plugin or die $!; local $/; <$fh> };
my ($writer) = $src =~ /(sub _write_file_atomic \{.*?\n\}\n)/s;
my ($json)   = $src =~ /(sub _write_json_atomic \{.*?\n\}\n)/s;
ok( $writer, 'the checked writer can be isolated' ) or BAIL_OUT('cannot extract');
ok( $json,   'and the json wrapper' );

## no critic (BuiltinFunctions::ProhibitStringyEval)
eval "use JSON::PP; $writer $json 1" or BAIL_OUT("cannot load: $@");
## use critic

my $d = tempdir( 'lazysite-write-XXXXXX', TMPDIR => 1, CLEANUP => 1 );

# --- the good path -----------------------------------------------------
my $good = "$d/day.json";
ok( _write_json_atomic( $good, { date => '2026-08-19', pageviews => 42 } ),
    'a normal write reports success' );
my $back = decode_json( do { open my $fh, '<', $good or die $!; local $/; <$fh> } );
is( $back->{pageviews}, 42, 'and the data round-trips' );

ok( !glob("$d/*.[0-9]*"), 'no temp file is left behind' );

# --- the write that cannot complete ------------------------------------
#
# A REAL failed write, not a failed open. The first version of this test used
# /dev/full and proved nothing: the writer appends ".$$" to the path, so it was
# opening /dev/full.12345, failing at open(), and taking a branch that existed in
# the broken code too. Both sabotages of the print/close checks passed against it.
#
# `ulimit -f` makes the write itself fail with EFBIG once the file exceeds the
# limit - no privileges, no mount, and it fires at print or at the flush inside
# close depending on buffering, which is exactly the pair being asserted. SIGXFSZ
# has to be ignored or the child is killed before it can report anything.
sub attempt_big_write {
    my ( $dir, $target, $pad, $ulimit ) = @_;
    $pad    //= 400_000;
    $ulimit //= 64;
    my $script = "$dir/run.pl";
    open my $sh, '>', $script or die $!;
    print {$sh} <<"RUN";
use strict;
use warnings;
use JSON::PP;
\$SIG{XFSZ} = 'IGNORE';
$writer
$json
my \$big = { date => '2026-08-19', pageviews => 42, pad => ( 'x' x $pad ) };
my \$ok = _write_json_atomic( '$target', \$big );
print \$ok ? "REPORTED_OK\n" : "REPORTED_FAIL\n";
RUN
    close $sh;
    my $out = `bash -c 'ulimit -f $ulimit; $^X \Q$script\E' 2>/dev/null`;
    chomp $out;
    return $out;
}

{
    my $dir  = tempdir( 'lazysite-full-XXXXXX', TMPDIR => 1, CLEANUP => 1 );
    my $file = "$dir/day.json";

    # A good file first, so there is something to destroy.
    _write_json_atomic( $file, { date => '2026-08-19', pageviews => 42 } );
    my $before = do { open my $fh, '<', $file or die $!; local $/; <$fh> };

    my $result = attempt_big_write( $dir, $file );
    is( $result, 'REPORTED_FAIL',
        'a write that runs out of room reports FAILURE rather than success' );

    # The load-bearing assertion. The old code renamed the truncated temp file
    # over this one and returned 1.
    my $after = do { open my $fh, '<', $file or die $!; local $/; <$fh> };
    is( $after, $before,
        'and the good file is untouched - a failed save does not destroy it' );

    my $parsed = eval { decode_json($after) };
    is( $parsed->{pageviews}, 42, 'it still parses, and still holds the old data' );

    ok( !glob("$dir/day.json.[0-9]*"), 'the truncated temp file is cleaned up' );
}

# The close(), on its own. Above, the payload is large enough that print() itself
# fails - so a writer that checked print and NOT close would pass everything
# above. This one is small enough to sit in Perl's output buffer, so print()
# succeeds and the failure surfaces only in the flush that close() performs.
# That is the case the pair exists for, and without it half the fix is untested.
{
    my $dir  = tempdir( 'lazysite-flush-XXXXXX', TMPDIR => 1, CLEANUP => 1 );
    my $file = "$dir/day.json";
    _write_json_atomic( $file, { date => '2026-08-19', pageviews => 42 } );
    my $before = do { open my $fh, '<', $file or die $!; local $/; <$fh> };

    is( attempt_big_write( $dir, $file, 1500, 1 ), 'REPORTED_FAIL',
        'a write that fails only at the FLUSH still reports failure' );

    my $after = do { open my $fh, '<', $file or die $!; local $/; <$fh> };
    is( $after, $before, 'and the good file survives that too' );
}

# --- every caller goes through it --------------------------------------
( my $code = $src ) =~ s/^\s*#.*$//mg;
unlike( $code, qr/rename \$tmp, _cache_path\(\)/,
    'the export cache no longer renames unchecked' );
like( $code, qr/_write_file_atomic\( _cache_path\(\)/,
    'it uses the checked writer' );
like( $code, qr/_write_json_atomic\( \$f, \{/,
    'and the trails writer does too' );

# One rename, in one place. Three copies of an atomic write is three chances to
# omit a check, which is how this happened.
is( scalar( () = $code =~ /\brename\b/g ), 1,
    'there is exactly one rename in the file' );

done_testing();
