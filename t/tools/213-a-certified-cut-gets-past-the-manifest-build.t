#!/usr/bin/perl
# SM1259: build-manifest.pl TAKES --channel certified.
#
# ADR 0010 added a fourth rung, and `tools/release.sh --certified` cuts on it by
# passing `--channel certified` to build-manifest.pl - which checked the value
# against edge|beta|stable and died. So the first certified cut would have
# stopped at the manifest build. The manifest records the channel, and
# install.pl ranks `certified` already, so the value only had to be let in.
#
# Run against the tree, as the release stage runs it, into a scratch file: the
# repo-root manifest other tests share is not touched.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use JSON::PP   qw(decode_json);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $ROOT = repo_root();
my $TOOL = "$ROOT/tools/build-manifest.pl";
my $tmp  = tempdir( CLEANUP => 1 );

sub build {
    my ($channel) = @_;
    my $out = "$tmp/manifest-$channel.json";
    my $cmd = join ' ', map {quotemeta} $^X, $TOOL, '--staged', $ROOT, '--out', $out,
        '--version', '9.9.9', '--channel', $channel;
    my $log = `$cmd 2>&1`;
    return ( $? >> 8, $log, $out );
}

my ( $rc, $log, $out ) = build('certified');
is( $rc, 0, 'a certified build gets past the channel check' ) or diag $log;
SKIP: {
    skip 'no manifest written', 1 unless -f $out;
    open my $fh, '<:raw', $out or die $!;
    my $m = decode_json( do { local $/; <$fh> } );
    close $fh;
    is( $m->{channel}, 'certified', 'and the manifest records the channel it was cut on' );
}

( $rc, $log ) = build('gold');
isnt( $rc, 0, 'an unknown channel is still refused' );
like( $log, qr/--channel must be 'edge', 'beta', 'stable' or 'certified'/,
    'naming the four rungs the ladder has' );

like( do { open my $r, '<', "$ROOT/tools/release.sh" or die $!; local $/; <$r> },
    qr/CHANNEL="certified"/, 'release.sh --certified is the caller that needs it' );

done_testing();
