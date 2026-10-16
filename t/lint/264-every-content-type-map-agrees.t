#!/usr/bin/perl
# SM1112: the engine's content-type maps agree, and every one knows media.
#
# Reported 2026-10-16, publishing interface clips to xisl.com: "`.mp4` /
# `.webm` are served as `application/octet-stream`" with nosniff, while the
# .png and .jpg beside them got their image types. The map that answered was the
# processor's %STATIC_CT, and it was one of FOUR - each surface that hands out a
# file keeps its own, for reasons each states:
#
#   lazysite-processor.pl           %STATIC_CT          the public static serve
#   lazysite-dav.pl                 %CONTENT_TYPE_MAP   DAV GET, loads no manager
#   lib/Lazysite/Manager/Upload.pm  %CONTENT_TYPE_MAP   manager downloads
#   tools/lazysite-server.pl        %MIME               the dev server's direct serve
#
# They are allowed to differ in WHAT they list (the processor's is kept small on
# purpose: unlisted is a download). They are not allowed to differ in what a
# listed extension IS - before this, .ico was image/x-icon on the public serve
# and image/vnd.microsoft.icon over DAV, and the dev server sent .js and .css
# without the charset production sends. And every one carries the media set,
# so a video is a video whichever surface it is fetched from.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root = repo_root();

my %MAPS = (
    'lazysite-processor.pl'          => qr/^our %STATIC_CT = \(\n(.*?)^\);/ms,
    'lazysite-dav.pl'                => qr/^my %CONTENT_TYPE_MAP = \(\n(.*?)^\);/ms,
    'lib/Lazysite/Manager/Upload.pm' => qr/^our %CONTENT_TYPE_MAP = \(\n(.*?)^\);/ms,
    'tools/lazysite-server.pl'       => qr/^my %MIME = \(\n(.*?)^\);/ms,
);

my %MEDIA = (
    mp4  => 'video/mp4',
    m4v  => 'video/mp4',
    webm => 'video/webm',
    ogv  => 'video/ogg',
    mp3  => 'audio/mpeg',
    ogg  => 'audio/ogg',
    oga  => 'audio/ogg',
    opus => 'audio/ogg',
    wav  => 'audio/wav',
    m4a  => 'audio/mp4',
    flac => 'audio/flac',
    vtt  => 'text/vtt; charset=utf-8',
);

my %map;
for my $rel ( sort keys %MAPS ) {
    open my $fh, '<', "$root/$rel" or die "$rel: $!";
    my $src = do { local $/; <$fh> };
    close $fh;
    my ($body) = $src =~ $MAPS{$rel};
    ok( defined $body, "$rel: the map is found" ) or next;
    for my $line ( split /\n/, $body ) {
        next unless $line =~ /^\s*(\w+)\s*=>\s*'([^']*)'/;
        $map{$rel}{$1} = $2;
    }
    cmp_ok( scalar keys %{ $map{$rel} }, '>=', 14, "$rel: and parsed" )
        or diag( 'A map that parses to nothing would agree with everything.' );
}

subtest 'every map carries the media types' => sub {
    for my $rel ( sort keys %map ) {
        for my $ext ( sort keys %MEDIA ) {
            is( $map{$rel}{$ext}, $MEDIA{$ext}, "$rel: .$ext is $MEDIA{$ext}" );
        }
    }
};

subtest 'an extension two maps list has one type' => sub {
    my %seen;
    for my $rel ( sort keys %map ) {
        push @{ $seen{$_}{ $map{$rel}{$_} } }, $rel for keys %{ $map{$rel} };
    }
    my $shared = 0;
    for my $ext ( sort keys %seen ) {
        my @types = sort keys %{ $seen{$ext} };
        my $n = 0;
        $n += @{ $seen{$ext}{$_} } for @types;
        next if $n < 2;
        $shared++;
        is( scalar @types, 1, ".$ext has one type across $n maps" )
            or diag( join "\n", map { "  $_: @{ $seen{$ext}{$_} }" } @types );
    }
    cmp_ok( $shared, '>=', 20, 'and the maps really do share extensions' );
};

done_testing();
