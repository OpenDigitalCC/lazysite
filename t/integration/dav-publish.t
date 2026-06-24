#!/usr/bin/perl
# SM070: end-to-end publishing - a DAV write becomes a served page, a
# re-write updates it (cache invalidated), a delete unpublishes it.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use MIME::Base64 qw(encode_base64);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root run_dav run_processor setup_minimal_site dav_users_tool);

my $docroot = tempdir( CLEANUP => 1 );
setup_minimal_site($docroot);
make_path("$docroot/lazysite/auth");

# Enable WebDAV and create a webdav-capable user.
open my $cf, '>>', "$docroot/lazysite/lazysite.conf" or die $!;
print $cf "webdav_enabled: true\n";
close $cf;
dav_users_tool( $docroot, 'add', 'deploy', 'secret' );
dav_users_tool( $docroot, 'set', 'deploy', 'webdav', 'on' );
my $auth = 'Basic ' . encode_base64( 'deploy:secret', '' );

# --- PUT publishes a page ---------------------------------------------
{
    my $put = run_dav( $docroot, 'PUT', '/published.md',
        body => "---\ntitle: Published\n---\nFIRST-VERSION\n",
        HTTP_AUTHORIZATION => $auth );
    is( $put->{code}, 201, 'PUT new page => 201' );

    my $out = run_processor( $docroot, '/published' );
    like( $out, qr/Status:\s*200/, 'processor serves the published page' );
    like( $out, qr/FIRST-VERSION/, 'page content rendered' );
}

# --- re-PUT updates it, cache invalidated -----------------------------
{
    # prime the rendered cache
    run_processor( $docroot, '/published' );
    my $put = run_dav( $docroot, 'PUT', '/published.md',
        body => "---\ntitle: Published\n---\nSECOND-VERSION\n",
        HTTP_AUTHORIZATION => $auth );
    is( $put->{code}, 204, 're-PUT => 204' );

    my $out = run_processor( $docroot, '/published' );
    like( $out, qr/SECOND-VERSION/, 'updated content served (cache dropped)' );
    unlike( $out, qr/FIRST-VERSION/, 'stale content gone' );
}

# --- DELETE unpublishes ------------------------------------------------
{
    my $del = run_dav( $docroot, 'DELETE', '/published.md', HTTP_AUTHORIZATION => $auth );
    is( $del->{code}, 204, 'DELETE => 204' );

    my $out = run_processor( $docroot, '/published' );
    like( $out, qr/Status:\s*404/, 'deleted page now 404s' );
}

# --- SM077: WebDAV writes land in the shared audit trail (origin=dav) ---
{
    my $log = "$docroot/lazysite/logs/audit.log";
    ok( -f $log, 'audit log created by the dav writes' );
    open my $lf, '<', $log or die $!;
    my @lines = <$lf>;
    close $lf;
    my @dav = grep { /\| dav\s*$/ } @lines;
    ok( scalar(@dav) >= 3, 'PUT, re-PUT and DELETE all recorded with origin=dav' )
        or diag( join '', @lines );
    ok( ( grep { /\| deploy \| put \|/ && /\| dav\s*$/ } @lines ),
        'a PUT is audited (user=deploy, action=put, origin=dav)' );
    ok( ( grep { /\| deploy \| delete \|/ && /\| dav\s*$/ } @lines ),
        'a DELETE is audited (origin=dav)' );
}

# --- SM077: @group ACLs are enforced over WebDAV (shared Auth::Acl) -----
{
    dav_users_tool( $docroot, 'add', 'eve', 'pw' );
    dav_users_tool( $docroot, 'set', 'eve', 'webdav', 'on' );
    dav_users_tool( $docroot, 'add', 'mallory', 'pw' );
    dav_users_tool( $docroot, 'set', 'mallory', 'webdav', 'on' );

    open my $gf, '>', "$docroot/lazysite/auth/groups" or die $!;
    print {$gf} "editors: eve\n";    # eve is a member; mallory is not
    close $gf;
    open my $af, '>', "$docroot/lazysite/auth/acls.json" or die $!;
    print {$af} '{"grouped.md":{"owner":"deploy","write":["@editors"]}}';
    close $af;

    my $eve = 'Basic ' . encode_base64( 'eve:pw', '' );
    my $mal = 'Basic ' . encode_base64( 'mallory:pw', '' );
    my $a = run_dav( $docroot, 'PUT', '/grouped.md', body => "x\n", HTTP_AUTHORIZATION => $eve );
    is( $a->{code}, 201, '@group member (eve in @editors) may PUT over WebDAV' );
    my $b = run_dav( $docroot, 'PUT', '/grouped.md', body => "y\n", HTTP_AUTHORIZATION => $mal );
    is( $b->{code}, 403, 'non-member (mallory) is denied by the @group ACL' );

    # Reads are audited too (so a partner's browse/read activity is visible).
    my $g = run_dav( $docroot, 'GET', '/grouped.md', HTTP_AUTHORIZATION => $eve );
    is( $g->{code}, 200, 'eve can GET the file (read open within scope)' );
    open my $l2, '<', "$docroot/lazysite/logs/audit.log" or die $!;
    my @al = <$l2>;
    close $l2;
    ok( ( grep { /\| eve \| get \|/ && /\| dav\s*$/ } @al ),
        'a GET (read) is recorded in the audit trail (origin=dav)' );
}

done_testing();
