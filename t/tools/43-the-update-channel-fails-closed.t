#!/usr/bin/perl
# SM356: the update channel failed open, in three different ways.
#
# `read_update_channel` returned 'all' - accept every build, edge included -
# when the conf could not be read, when there was no `update_channel` line, and
# WHEN THE VALUE WAS NOT RECOGNISED.
#
# The third is the one that matters. `update_channel: stabel` did not fail, did
# not warn, and did not mean stable. It meant the most permissive setting
# available, silently. An operator who typed the word they meant, with one
# letter wrong, got the exact opposite of what they asked for - and the only
# symptom is a pre-release build arriving on a customer site, which looks like a
# rollout problem rather than a typo.
#
# `channel_refuses` had the same shape twice more: `$CHANNEL_RANK{$x} // 0`, and
# 0 is `edge`, which accepts everything. So any rung either side failed to
# recognise resolved to "install it". A comparison whose unknown case is the
# permissive one is not a gate.
#
# REPORTED as "an edge rollout touched sites it was not for" ([[SM345]]). The
# gate was working. The default was wrong, and a default that is wrong in the
# permissive direction is indistinguishable from no default at all.
#
# Driven through the REAL installer rather than asserted against the source,
# because the question is what happens to a site, not what the code says.
use strict;
use warnings;
use Test::More;
use JSON::PP   qw(encode_json);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root    = repo_root();
my $install = "$root/install.pl";
ok( -f $install, 'the installer is present' );

# A docroot with an install state and a conf, so --channel-check reaches the
# channel decision instead of returning early on "not an upgrade".
sub site_with_channel {
    my ($line) = @_;
    my $d = tempdir( CLEANUP => 1 );
    make_path("$d/lazysite");
    open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
    print $cf "site_url: https://demo.example.io\n";
    print $cf "$line\n" if defined $line;
    close $cf;
    open my $st, '>', "$d/lazysite/.install-state.json" or die $!;
    print $st encode_json( { version => '0.0.1', files => {} } );
    close $st;
    return $d;
}

# Stage a manifest declaring a channel, and ask whether this site accepts it.
# Exit 3 = refused, 0 = accepted.
#
# The installer takes its stage directory from its OWN location
# (`abs_path(dirname($0))`) - there is no --stage option - so the manifest has
# to sit beside a copy of the script, exactly as a real deploy does when it runs
# `$STAGE/install.sh`. The first version of this passed a --stage flag the
# installer ignores, so every case reached a manifest that was not there and
# every case came back 'accepted'. That looked like a catastrophic gate failure
# and was a broken harness - the tell was that `update_channel: stable`
# accepted an edge build, which no version of this code has ever done.
sub accepts {
    my ( $docroot, $channel ) = @_;
    my $stage = tempdir( CLEANUP => 1 );
    open my $mf, '>', "$stage/release-manifest.json" or die $!;
    print $mf encode_json(
        { version => '9.9.9', channel => $channel, files => {} } );
    close $mf;

    open my $in,  '<', $install            or die $!;
    open my $out, '>', "$stage/install.pl" or die $!;
    print {$out} do { local $/; <$in> };
    close $out;
    close $in;

    my $rc = system(
        $^X, "$stage/install.pl", '--channel-check',
        '--docroot' => $docroot,
    );
    return ( $rc >> 8 ) == 3 ? 0 : 1;
}

subtest 'an unrecognised value is not a licence to install anything' => sub {
    # THE FIELD CASE. One letter wrong in the word the operator meant.
    # No SKIP guard here. The first version had one, to tolerate a harness that
    # could not stage a manifest - and a skip is how a test that measures
    # nothing reports success, which is the defect this suite exists to remove.
    # The harness was fixed instead.
    my $typo = site_with_channel('update_channel: stabel');
    ok( !accepts( $typo, 'edge' ),
        "a site reading 'stabel' refuses an edge build" )
        or diag( 'It used to accept it. An unrecognised value resolved to '
            . "'all', the most permissive rung, in silence - so a typo "
            . 'granted more than the word it was trying to spell.' );
    ok( !accepts( $typo, 'beta' ), 'and refuses a beta build' );
    ok( accepts( $typo,  'stable' ),
        'and still accepts the build it was trying to ask for' );
};

subtest 'the certified rung sits above stable (ADR 0010)' => sub {
    # certified is a MATURITY, so the minimum-accepted rule applies unchanged:
    # a stable site takes certified builds (more mature than it demands), a
    # certified site takes ONLY certified builds, and a certified build is not
    # a skeleton key downward.
    my $st = site_with_channel('update_channel: stable');
    ok( accepts( $st, 'certified' ), 'a stable site accepts a certified build' );

    my $ct = site_with_channel('update_channel: certified');
    ok( accepts( $ct,  'certified' ), 'a certified site accepts a certified build' );
    ok( !accepts( $ct, 'stable' ),    'and refuses a stable one' );
    ok( !accepts( $ct, 'beta' ),      'and beta' );
    ok( !accepts( $ct, 'edge' ),      'and edge' );
};

subtest 'an absent channel is a policy, and the safe one' => sub {
    my $none = site_with_channel(undef);
    ok( !accepts( $none, 'edge' ),
        'a site with no update_channel refuses an edge build' )
        or diag( 'The default was "accept everything", so every site that had '
            . 'never been given a channel took pre-release builds - which is '
            . 'the opposite of what an unconfigured site should do.' );
    ok( accepts( $none, 'stable' ),
        'and accepts a stable one, so it is not simply frozen' );
};

subtest 'the recognised rungs still behave' => sub {
    # The half that must not regress. A fail-closed default is worthless if it
    # also breaks the settings people did configure.
    # SM423: 'certified' belongs in the EXHAUSTIVE matrix, not only in its own
    # subtest. A matrix that enumerates three rungs while the ladder has four
    # still reads as exhaustive, which is the way a coverage claim goes stale
    # without anybody editing it.
    my %expect = (
        'update_channel: edge' =>
            { edge => 1, beta => 1, stable => 1, certified => 1 },
        'update_channel: beta' =>
            { edge => 0, beta => 1, stable => 1, certified => 1 },
        'update_channel: stable' =>
            { edge => 0, beta => 0, stable => 1, certified => 1 },
        'update_channel: certified' =>
            { edge => 0, beta => 0, stable => 0, certified => 1 },
        'update_channel: all' =>
            { edge => 1, beta => 1, stable => 1, certified => 1 },
    );
    for my $line ( sort keys %expect ) {
        my $d = site_with_channel($line);
        for my $rel ( sort keys %{ $expect{$line} } ) {
            is( accepts( $d, $rel ), $expect{$line}{$rel},
                "$line " . ( $expect{$line}{$rel} ? 'accepts' : 'refuses' )
                    . " a $rel build" );
        }
    }
};

subtest 'the ranks are declared, not reached by falling through' => sub {
    # `all` used to mean 0 only because it was absent from the map and `// 0`
    # caught it - the same way a typo did. A rung reachable only by failing to
    # recognise something cannot be told apart from a mistake.
    my $src = do { open my $fh, '<', $install or die $!; local $/; <$fh> };
    like( $src, qr/%CHANNEL_RANK = \([^)]*\ball\b/,
        "'all' is a declared rung" );
    unlike( $src, qr/\$CHANNEL_RANK\{[^}]*\}\s*\/\/\s*0/,
        'and no lookup falls through to the most permissive rung' )
        or diag( '`// 0` is `edge`, which accepts everything. An unknown value '
            . 'must fail closed.' );
};

done_testing();
