#!/usr/bin/perl
# SM334: the settings read is memoised, and cannot answer an access question
# from a superseded file.
#
# WHY IT IS MEMOISED. `touch_credential` reads the settings on EVERY token
# verification, to decide whether the "last used" stamp is stale enough to
# rewrite. Its comment calls that "one cheap read". It opens, slurps and
# decode_json's the whole user-settings file, and under the FastCGI pool one
# worker does that for every authenticated request it serves.
#
# Measured across the release line: verify_token_ms drifted 32.7 -> 41.7 ms since
# the 2026-07-02 baseline, and a bisect put the largest single step - +2.9 ms,
# +8% - between v0.7.24 and v0.7.26, the window that added this read (SM163).
# Every step passed the 2x perf tolerance.
#
# WHY THE CACHE IS DANGEROUS, AND WHAT MAKES IT SAFE. This decides who may do
# what. A stale entry is an access-control answer from the past: a capability
# revoked through the CLI would keep working until the entry expired. So it is
# keyed on the FILE'S IDENTITY (mtime, size) rather than on a clock - a write
# invalidates it, and correctness does not depend on a window being short enough.
#
# Two holes that keying alone does not close, both covered below:
#
#   - mtime is ONE-SECOND granular, so a write in the same second with the same
#     size carries an identical key. `"ui":1` -> `"ui":0` is exactly that shape.
#   - a process that writes the file itself must not answer from what it just
#     superseded, where the gap is milliseconds rather than a second.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../../lib";
use Lazysite::Auth::Settings ();

my $dir = tempdir( CLEANUP => 1 );
make_path("$dir/auth");
local $Lazysite::Auth::Settings::AUTH_DIR = "$dir/auth";

sub settings_file { "$dir/auth/user-settings.json" }

sub write_raw {
    my ($json) = @_;
    open my $fh, '>', settings_file() or die $!;
    print $fh $json;
    close $fh;
    return;
}

subtest 'a repeated read is served without re-parsing' => sub {
    write_raw('{"alice":{"ui":1}}');
    # Age it past the just-written guard so it is cacheable at all.
    my $old = time() - 60;
    utime $old, $old, settings_file();

    my $first = Lazysite::Auth::Settings::read_settings();
    is( $first->{alice}{ui}, 1, 'the first read is correct' );

    # Replace the CONTENT without touching mtime or size: only a cache would
    # return the old value, which is how we prove one is in use.
    my $swapped = '{"alice":{"ui":0}}';
    is( length $swapped, length '{"alice":{"ui":1}}', 'fixture keeps the size identical' );
    write_raw($swapped);
    utime $old, $old, settings_file();

    my $second = Lazysite::Auth::Settings::read_settings();
    is( $second->{alice}{ui}, 1,
        'the cached entry is returned - the memoisation is real' )
        or diag( 'If this reads 0 the cache is not working and the perf fix '
            . 'does nothing.' );
};

subtest 'a file written THIS SECOND is never cached' => sub {
    # The hole keying cannot close: same second, same size, different content.
    # A capability flip is exactly that shape, and this is an access decision.
    Lazysite::Auth::Settings::_settings_cache_clear();

    write_raw('{"bob":{"ui":1}}');    # mtime = now
    my $a = Lazysite::Auth::Settings::read_settings();
    is( $a->{bob}{ui}, 1, 'read while fresh' );

    write_raw('{"bob":{"ui":0}}');    # same second, same size, revoked
    my $b = Lazysite::Auth::Settings::read_settings();
    is( $b->{bob}{ui}, 0,
        'the revocation is seen immediately, not after the second turns over' )
        or diag( "A capability revoked and then exercised inside one second\n"
            . "would still be honoured. That is not a cache miss, it is an\n"
            . "access-control failure." );
};

subtest 'writing the settings clears this process cache' => sub {
    # The same-process case: a capability change and the next authorisation are
    # milliseconds apart, and the writer is the one that must not be stale.
    Lazysite::Auth::Settings::_settings_cache_clear();

    write_raw('{"carol":{"ui":1}}');
    my $old = time() - 60;
    utime $old, $old, settings_file();
    my $before = Lazysite::Auth::Settings::read_settings();
    is( $before->{carol}{ui}, 1, 'cached while permitted' );

    Lazysite::Auth::Settings::write_settings( { carol => { ui => 0 } } );

    my $after = Lazysite::Auth::Settings::read_settings();
    is( $after->{carol}{ui}, 0,
        'the writer sees its own change' )
        or diag( 'write_settings must clear the cache: the (mtime,size) key '
            . 'covers ANOTHER process writing, not this one.' );
};

subtest 'the cache is bounded' => sub {
    # One entry per (file, mtime, size). A long-lived worker outliving many
    # writes must not accumulate them indefinitely.
    Lazysite::Auth::Settings::_settings_cache_clear();
    for my $i ( 1 .. 20 ) {
        write_raw( sprintf '{"u%02d":{"ui":1}}', $i );
        my $old = time() - 60 - $i;
        utime $old, $old, settings_file();
        Lazysite::Auth::Settings::read_settings();
    }
    my $src = do {
        open my $fh, '<', "$FindBin::Bin/../../../lib/Lazysite/Auth/Settings.pm"
            or die $!;
        local $/;
        <$fh>;
    };
    like( $src, qr/keys %_settings_cache > 8/,
        'the map is capped rather than growing without limit' );
    pass('twenty distinct versions read without incident');
};

done_testing();
