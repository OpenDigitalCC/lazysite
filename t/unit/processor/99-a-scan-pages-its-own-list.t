#!/usr/bin/perl
# P9 revise (WORK-PLAN-0154, ruled 2026-10-12 "Keep, add per-scan limit="):
# `scan_limit:` stays the site's ceiling on how many pages a scan reads, and a
# scan directive gains `limit=` and `offset=`, which page the filtered, sorted
# list and are capped by the ceiling. `<var>_total` is as built (SM988): the
# pages the pattern matched that the reader may see, before filter= and paging.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(setup_minimal_site run_processor site_tempdir);

sub spit { my ( $p, $t ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh; return }

my $docroot = site_tempdir();
setup_minimal_site($docroot);
make_path("$docroot/post");

# Nine posts, P01 the oldest; odd ones are kind: odd.
for my $i ( 1 .. 9 ) {
    spit(
        sprintf( "$docroot/post/p%02d.md", $i ),
        sprintf( "---\ntitle: P%02d\ndate: 2026-01-%02d\nkind: %s\n---\nBody.\n",
            $i, 10 + $i, $i % 2 ? 'odd' : 'even' )
    );
}

sub page {
    my ( $directive, $conf ) = @_;
    spit( "$docroot/lazysite/lazysite.conf", "site_name: Test\nsite_url: http://localhost\n" . ( $conf // '' ) );
    spit( "$docroot/list.md", <<"MD" );
---
title: List
tt_page_var:
  posts: scan:/post/*.md $directive
---
COUNT=[% posts.size %] TOTAL=[% posts_total %] [% FOREACH p IN posts %]|[% p.title %]|[% END %]
MD
    unlink "$docroot/list.html";
    return run_processor( $docroot, '/list' ) // '';
}

subtest 'limit= takes the first N of the sorted list' => sub {
    my $o = page('sort=date desc limit=3');
    like( $o, qr/COUNT=3 TOTAL=9 /,      'three listed, nine matched' );
    like( $o, qr/\|P09\|\|P08\|\|P07\|/, 'the newest three, newest first' );
};

subtest 'offset= skips into the sorted list' => sub {
    my $o = page('sort=date desc offset=3 limit=3');
    like( $o, qr/COUNT=3 TOTAL=9 /,                               'the second three' );
    like( $o, qr/\|P06\|\|P05\|\|P04\|/,                          'P06, P05, P04' );
    like( page('sort=date desc offset=8'), qr/COUNT=1 .*\|P01\|/, 'offset alone: the rest' );
    like( page('sort=date desc offset=50'), qr/COUNT=0 TOTAL=9 /, 'an offset past the end lists nothing' );
};

subtest 'paging applies after filter=' => sub {
    my $o = page('filter=kind:odd sort=date desc offset=1 limit=2');
    like( $o, qr/COUNT=2 TOTAL=9 /, 'two of the odd ones; the total is before the filter, as built' );
    like( $o, qr/\|P07\|\|P05\|/, 'the second and third odd posts' );
};

subtest 'limit= is capped by the site ceiling' => sub {
    my $o = page( 'sort=filename asc limit=50', "scan_limit: 4\n" );
    like( $o, qr/COUNT=4 TOTAL=9 /, 'limit=50 under scan_limit: 4 lists four' );
    like( $o, qr/\|P01\|\|P02\|\|P03\|\|P04\|/, 'the ceiling still reads the stable prefix' );
    like( page( 'sort=filename asc offset=4', "scan_limit: 4\n" ),
        qr/COUNT=0 /, 'offset= reaches no further than the ceiling read' );
};

subtest 'a bad value is ignored and never reaches the glob' => sub {
    for my $bad ( 'limit=0', 'limit=abc', 'offset=-1', 'limit=', 'offset=x' ) {
        like( page("sort=date desc $bad"), qr/COUNT=9 TOTAL=9 /, "$bad: the whole list" );
    }
};

done_testing;
