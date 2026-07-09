#!/usr/bin/perl
# The TT on-disk compile cache must never break rendering, and a manager-layout
# failure must be loud, not silent. Field-hit 2026-07-09: on Template Toolkit
# 2.x an unwritable cache/tt subtree made every layout render fail ("cache
# failed to write ... .ttc"), silently downgrading the manager UI to the
# built-in fallback chrome. Pins:
# - an unwritable compile-cache dir still renders the manager layout
#   (first attempt on tolerant TT 3.x; the no-compile-cache retry on TT 2.x)
# - a genuinely broken manager layout falls back WITH a visible operator
#   banner (manager pages are auth-gated - safe to show the error)
# - a broken public layout falls back silently (no error leak to visitors)
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(run_processor);

plan skip_all => 'root ignores directory modes - unwritable-dir case untestable'
    if $> == 0;

my $MG_CHROME = qr{id="mg-shell"};
my $BANNER    = qr{id="ls-layout-error"};

sub fresh_site {
    my $d = tempdir( CLEANUP => 1 );
    make_path( "$d/lazysite/manager", "$d/lazysite/auth", "$d/manager" );
    open my $c, '>', "$d/lazysite/lazysite.conf" or die $!;
    print $c "site_name: T\nmanager: enabled\nauth_proxy_trusted: true\n";
    close $c;
    open my $g, '>', "$d/lazysite/auth/groups-settings.json" or die $!;
    print $g '{"admins":{"label":"Admins","ui":1}}';
    close $g;
    open my $m, '>', "$d/manager/config.md" or die $!;
    print $m "---\ntitle: Site settings\nauth: manager\n---\nSETTINGS-BODY\n";
    close $m;
    open my $i, '>', "$d/index.md" or die $!;
    print $i "---\ntitle: Home\n---\nHOME-BODY\n";
    close $i;
    return $d;
}

sub write_manager_layout {
    my ( $d, $tt ) = @_;
    open my $l, '>', "$d/lazysite/manager/layout.tt" or die $!;
    print $l $tt;
    close $l;
    return;
}

my $GOOD_LAYOUT = '<!DOCTYPE html><html><head><title>[% page_title %]</title>'
    . '</head><body><div id="mg-shell">[% content %]</div></body></html>';

subtest 'unwritable compile cache: manager layout still renders' => sub {
    my $d = fresh_site();
    write_manager_layout( $d, $GOOD_LAYOUT );
    make_path("$d/lazysite/cache/tt");
    chmod 0555, "$d/lazysite/cache/tt" or die $!;

    my $out = run_processor( $d, '/manager/config',
        HTTP_X_REMOTE_USER => 'alice', HTTP_X_REMOTE_GROUPS => 'admins' );
    like( $out, $MG_CHROME,        'manager chrome rendered despite read-only cache/tt' );
    like( $out, qr{SETTINGS-BODY}, 'page content present' );
    unlike( $out, qr{class="site-bar"}, 'not the built-in fallback layout' );

    chmod 0755, "$d/lazysite/cache/tt";    # let tempdir CLEANUP remove it
};

subtest 'broken manager layout: fallback carries a loud operator banner' => sub {
    my $d = fresh_site();
    write_manager_layout( $d, '[% IF broken %]never closed' );

    my $out = run_processor( $d, '/manager/config',
        HTTP_X_REMOTE_USER => 'alice', HTTP_X_REMOTE_GROUPS => 'admins' );
    like( $out, $BANNER, 'ls-layout-error banner present on the manager page' );
    like( $out, qr{Manager layout failed to render}, 'banner says what broke' );
    like( $out, qr{SETTINGS-BODY}, 'content still served via the fallback' );
};

subtest 'broken public layout: silent fallback, no error leak' => sub {
    my $d = fresh_site();
    write_manager_layout( $d, $GOOD_LAYOUT );
    make_path("$d/lazysite/layouts/default");
    open my $l, '>', "$d/lazysite/layouts/default/layout.tt" or die $!;
    print $l '[% IF broken %]never closed';
    close $l;
    open my $c, '>>', "$d/lazysite/lazysite.conf" or die $!;
    print $c "layout: default\n";
    close $c;

    my $out = run_processor( $d, '/' );
    like( $out, qr{HOME-BODY}, 'public page served via the fallback' );
    unlike( $out, $BANNER,                       'no error banner for visitors' );
    unlike( $out, qr{never closed|parse error}i, 'no template error text leaked' );
};

done_testing;
