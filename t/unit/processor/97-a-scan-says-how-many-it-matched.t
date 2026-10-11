#!/usr/bin/perl
# P9 (WORK-PLAN-0154): a scan says how many pages it matched, and its cap is
# the site's to set.
#
# Reported from a 1,745-post site: `scan:/post/*.md sort=date desc` returned 200
# entries - the first 200 files by name, then sorted - with nothing to say the
# cap was hit, so a page built on it rendered short and looked complete.
#
# The cap stays (a scan reads every page it lists), stays 200 by default, and
# still takes a stable prefix in file order. `scan_limit:` in lazysite.conf sets
# it. `<var>_total` carries the number of pages the pattern matched that the
# reader may see, before `filter=` and before the cap, so a page can say
# "showing 200 of 1,745" - and a gated page is not counted, so the number says
# nothing about what the reader may not see.
use strict;
use warnings;
use Test::More;
use JSON::PP   qw(encode_json);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(setup_minimal_site run_processor site_tempdir);

sub spit { my ( $p, $t ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh; return }

my $docroot = site_tempdir();
setup_minimal_site($docroot);
make_path( "$docroot/post/private", "$docroot/lazysite/auth" );

# Seven public posts, the newest last by name, and one gated.
for my $i ( 1 .. 7 ) {
    spit( sprintf( "$docroot/post/p%02d.md", $i ),
        sprintf( "---\ntitle: P%02d\ndate: 2026-01-%02d\n---\nBody.\n", $i, 10 + $i ) );
}
spit( "$docroot/post/private/secret.md", "---\ntitle: SECRET\ndate: 2026-02-01\n---\nHidden.\n" );
spit( "$docroot/lazysite/auth/acls.json", encode_json( { 'post/private' => { read => ['@editors'] } } ) );

spit( "$docroot/list.md", <<'MD' );
---
title: List
tt_page_var:
  posts: scan:/post/**/*.md sort=date desc
---
COUNT=[% posts.size %] TOTAL=[% posts_total %] [% FOREACH p IN posts %]|[% p.title %]|[% END %]
MD

sub conf {
    my ($extra) = @_;
    spit( "$docroot/lazysite/lazysite.conf", "site_name: Test\nsite_url: http://localhost\n$extra" );
    unlink "$docroot/list.html";
    return;
}
sub list { my $o = run_processor( $docroot, '/list' ) // ''; return $o }

subtest 'under the cap, the total is the list' => sub {
    conf('');
    my $o = list();
    like( $o, qr/COUNT=7 TOTAL=7 /, 'seven listed, seven matched' );
    unlike( $o, qr/SECRET/, 'the gated page is not listed' );
};

subtest 'over the cap, the total says how many there were' => sub {
    conf("scan_limit: 5\n");
    my $o = list();
    like( $o, qr/COUNT=5 TOTAL=7 /, 'five listed, seven matched' );
    like( $o, qr/\|P05\|\|P04\|\|P03\|\|P02\|\|P01\|/,
        'the five are the first in file order, then sorted: the stable prefix' );
    unlike( $o, qr/\|P0[67]\|/, 'the newest two lie past the cap, as documented' );
};

subtest 'the total counts only what the reader may see' => sub {
    conf("scan_limit: 50\n");
    like( list(), qr/TOTAL=7 /, 'the gated page is not counted' );
};

subtest 'an unusable scan_limit is the default' => sub {
    for my $bad ( 'abc', '0', '-3' ) {
        conf("scan_limit: $bad\n");
        like( list(), qr/COUNT=7 TOTAL=7 /, "scan_limit: $bad" );
    }
};

done_testing;
