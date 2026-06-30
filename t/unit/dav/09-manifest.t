#!/usr/bin/perl
# SM071 Phase 3: content-hash manifest - the lzs:sha256 PROPFIND property
# over the layouts subtree.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use Digest::SHA qw(sha256_hex);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(run_dav setup_dav_site dav_users_tool grant_caps revoke_caps);

my $s    = setup_dav_site(
    conf => "webdav_enabled: true\nlayout: base\ntheme: live\n" );
my $doc  = $s->{docroot};
my $auth = $s->{auth};
grant_caps( $doc, 'deploy', 'manage_themes' );

make_path("$doc/lazysite/layouts/base/themes/live");
my $body = "body { color: rebeccapurple; }\n";
open my $f, '>', "$doc/lazysite/layouts/base/themes/live/style.css" or die $!;
print $f $body; close $f;
my $expected = sha256_hex($body);

# P-perf: lzs:sha256 is computed only when the client requests it by name.
my $sha_req = '<?xml version="1.0"?>'
    . '<propfind xmlns:D="DAV:" xmlns:lzs="urn:lazysite:dav">'
    . '<prop><lzs:sha256/></prop></propfind>';

# --- theme file carries lzs:sha256 (when requested) matching content --
my $r = run_dav( $doc, 'PROPFIND', '/lazysite/layouts/base/themes/live/style.css',
    HTTP_AUTHORIZATION => $auth, HTTP_DEPTH => '0', body => $sha_req );
is( $r->{code}, 207, 'PROPFIND on theme file ok' );
like( $r->{body}, qr/xmlns:lzs="urn:lazysite:dav"/, 'lzs namespace declared' );
like( $r->{body}, qr{<lzs:sha256>\Q$expected\E</lzs:sha256>},
    'lzs:sha256 matches the file content hash' );

# --- not computed for a plain (allprop) PROPFIND - the davfs2 fast path -
my $rp = run_dav( $doc, 'PROPFIND', '/lazysite/layouts/base/themes/live/style.css',
    HTTP_AUTHORIZATION => $auth, HTTP_DEPTH => '0' );
is( $rp->{code}, 207, 'PROPFIND (allprop) on theme file ok' );
unlike( $rp->{body}, qr/lzs:sha256/,
    'lzs:sha256 skipped when the client did not request it' );

# --- content files do not carry the property (scoped to layouts) ------
open my $c, '>', "$doc/content/page.md" or die $!;
print $c "hello\n"; close $c;
my $cr = run_dav( $doc, 'PROPFIND', '/content/page.md',
    HTTP_AUTHORIZATION => $auth, HTTP_DEPTH => '0' );
is( $cr->{code}, 207, 'PROPFIND on content file ok' );
unlike( $cr->{body}, qr/lzs:sha256/, 'content file carries no lzs:sha256' );

done_testing();
