#!/usr/bin/perl
# SM1390 (ruling 147), the preview verifier's half: a value shaped like a
# session cookie is not a preview.
#
# The preview cookie and the session cookie are signed with one key. A session
# for an account named `v1` is `v1:<ts>:<sid>:<groups>`, and check_preview read
# that as a preview of layout <sid>, theme <groups>, for as long as its issue
# time was still ahead of the clock. A preview is minted with exactly five
# fields (the user may be empty; its colon is not), so the field count tells
# the two apart. t/unit/auth/76 holds the session verifier's half.
use strict;
use warnings;
use Test::More;
use File::Path  qw(make_path);
use Digest::SHA qw(hmac_sha256_hex);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(run_processor site_tempdir);

my $docroot = site_tempdir();
make_path("$docroot/lazysite/layouts/base/themes/$_") for qw(live candidate);
make_path("$docroot/lazysite/auth");
sub spit { open my $fh, '>', $_[0] or die $!; print {$fh} $_[1]; close $fh }
spit( "$docroot/lazysite/lazysite.conf", "site_name: T\nsite_url: http://localhost\nlayout: base\ntheme: live\n" );
spit( "$docroot/lazysite/layouts/base/layout.tt",
    '<!DOCTYPE html><html><body>MARK:[% layout_name %]/[% theme_name %]:KRAM[% content %]</body></html>' );
spit( "$docroot/lazysite/layouts/base/themes/$_/theme.json", qq({"name":"$_","layouts":["base"]}) ) for qw(live candidate);
spit( "$docroot/index.md", "---\ntitle: Home\n---\nHome body.\n" );
spit( "$docroot/404.md",   "---\ntitle: NF\n---\nnf\n" );
my $secret = 'c' x 64;
spit( "$docroot/lazysite/auth/.secret", "$secret\n" );

sub as_preview { my ($p) = @_; return "lzs_preview=$p:" . hmac_sha256_hex( $p, $secret ) }
my $soon = time() + 3600;

subtest 'a five-field preview still previews' => sub {
    my $out = run_processor( $docroot, '/index', HTTP_COOKIE => as_preview("v1:$soon:base:candidate:tester") );
    like( $out, qr{MARK:base/candidate:KRAM}, 'the candidate theme renders' );
    $out = run_processor( $docroot, '/index', HTTP_COOKIE => as_preview("v1:$soon:base:candidate:") );
    like( $out, qr{MARK:base/candidate:KRAM}, 'with an empty user as well - five fields, one empty' );
};

subtest 'a session-shaped value is not a preview' => sub {
    # user `v1`, an issue time an hour ahead (what the skew refusal exists for
    # on the session side), a sid-shaped layout, a group-shaped theme.
    my $out = run_processor( $docroot, '/index', HTTP_COOKIE => as_preview("v1:$soon:base:candidate") );
    like( $out, qr{MARK:base/live:KRAM}, 'four fields: the active theme renders, no preview' )
        or diag $out;
    unlike( $out, qr{Cache-Control:\s*no-store}i, 'and the page is not marked as a preview' );
    $out = run_processor( $docroot, '/index', HTTP_COOKIE => as_preview("v1:$soon:candidate") );
    like( $out, qr{MARK:base/live:KRAM}, 'three fields: the same' );
};

done_testing();
