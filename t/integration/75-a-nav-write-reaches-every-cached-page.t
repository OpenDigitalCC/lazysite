#!/usr/bin/perl
# SM536: navigation is the one element on every page, so a nav file written
# by ANY surface has to reach every cached render. The manager's action_save
# answered a nav.conf write by dropping every generated .html (SM087); a DAV
# PUT answered with the per-page invalidation, a no-op for a non-.md path,
# and the processor judged a cached render fresh on the .md and
# lazysite.conf mtimes alone - never on the nav file it baked in. So after a
# DAV PUT of lazysite/nav.conf the next request served the old navigation,
# and a per-domain lazysite/nav-<site>.conf (SM443) missed through every
# writer.
#
# The assertion is on the RENDERED nav, one per surface - the artefact a
# visitor meets, not the cache file - because the durable answer lives in
# the processor (the resolved nav file's mtime is part of the freshness
# check) and covers writers this test never drives.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(setup_dav_site run_dav run_processor);

my $HOST = 'xisl.example';

sub nav_site {
    my $s = setup_dav_site(
        conf => "webdav_enabled: true\nsite_name: T\nsite_url: http://localhost\n"
            . "layout: test\nnav_file: lazysite/nav.conf\n"
            . "alias_hosts: $HOST\n"
            . "alias.$HOST.content_root: sites/xisl\n"
            . "alias.$HOST.nav_file: lazysite/nav-xisl.conf\n" );
    my $d = $s->{docroot};
    make_path("$d/lazysite/layouts/test");
    open my $lf, '>', "$d/lazysite/layouts/test/layout.tt" or die $!;
    print {$lf} '<html><body>NAV:[% FOREACH n IN nav %][% n.label %];[% END %]|[% content %]</body></html>';
    close $lf;
    _write( "$d/lazysite/nav.conf",      "Home | /\nOld | /old\n" );
    _write( "$d/lazysite/nav-xisl.conf", "Home | /\nXOld | /xold\n" );
    _write( "$d/index.md",               "---\ntitle: Home\n---\nHome page.\n" );
    make_path("$d/sites/xisl");
    _write( "$d/sites/xisl/index.md", "---\ntitle: X\n---\nX page.\n" );
    return $s;
}

sub _write {
    my ( $path, $body ) = @_;
    open my $fh, '>', $path or die "$path: $!";
    print {$fh} $body;
    close $fh;
    return;
}

# The rendered nav labels of /index, primary or alias host.
sub nav_of {
    my ( $d, %env ) = @_;
    my $out = run_processor( $d, '/index', %env );
    my ($nav) = $out =~ /NAV:([^|]*)\|/;
    return $nav // "(no nav in: $out)";
}

# A cached render must be OLDER than the nav write for the check to have
# something to compare. Filesystems with one-second mtimes need the gap.
sub settle { sleep 1; return }

subtest 'a DAV PUT of lazysite/nav.conf reaches the cached page' => sub {
    my $s = nav_site();
    my $d = $s->{docroot};
    like( nav_of($d), qr/Old;/, 'the first render carries the old nav' );
    ok( -f "$d/index.html", 'and is cached' ) or return;
    settle();
    my $r = run_dav( $d, 'PUT', '/lazysite/nav.conf',
        body => "Home | /\nNew | /new\n", HTTP_AUTHORIZATION => $s->{auth} );
    ok( $r->{code} == 201 || $r->{code} == 204, "the PUT is accepted ($r->{code})" )
        or diag $r->{body};
    my $nav = nav_of($d);
    like( $nav, qr/New;/, 'the next render carries the NEW nav' ) or diag $nav;
    unlike( $nav, qr/Old;/, 'and no longer the old one' );
};

subtest 'a DAV PUT of a per-domain nav-<site>.conf reaches that domain\'s cached page'
    => sub {
    my $s = nav_site();
    my $d = $s->{docroot};
    like( nav_of( $d, HTTP_HOST => $HOST ), qr/XOld;/, 'the alias host renders its own nav' );
    like( nav_of($d), qr/Old;/, 'the primary renders the shared one' );
    settle();
    my $r = run_dav( $d, 'PUT', '/lazysite/nav-xisl.conf',
        body => "Home | /\nXNew | /xnew\n", HTTP_AUTHORIZATION => $s->{auth} );
    ok( $r->{code} == 201 || $r->{code} == 204, "the PUT is accepted ($r->{code})" )
        or diag $r->{body};
    my $nav = nav_of( $d, HTTP_HOST => $HOST );
    like( $nav, qr/XNew;/, 'the alias host\'s next render carries ITS new nav' ) or diag $nav;
    unlike( $nav, qr/XOld;/, 'and no longer the old one' );
    like( nav_of($d), qr/Old;/, 'the primary, whose nav file did not change, keeps its render' );
    };

subtest 'the manager\'s action_save of lazysite/nav.conf (control)' => sub {
    my $s = nav_site();
    my $d = $s->{docroot};
    like( nav_of($d), qr/Old;/, 'the first render carries the old nav' );
    settle();
    require Lazysite::Manager::Files;
    local $Lazysite::Manager::Files::DOCROOT  = $d;
    local $Lazysite::Manager::Common::DOCROOT = $d;
    local $Lazysite::Auth::Acl::DOCROOT       = $d;
    my $r = Lazysite::Manager::Files::action_save( 'lazysite/nav.conf', $s->{user},
        "Home | /\nNew | /new\n" );
    ok( $r->{ok}, 'action_save ok' ) or diag explain $r;
    like( nav_of($d), qr/New;/, 'the next render carries the new nav' );
};

done_testing();
