#!/usr/bin/perl
# SM070: class-2 LOCK / UNLOCK.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(setup_dav_site run_dav);

my $LOCKBODY = '<?xml version="1.0"?><D:lockinfo xmlns:D="DAV:">'
    . '<D:lockscope><D:exclusive/></D:lockscope>'
    . '<D:locktype><D:write/></D:locktype>'
    . '<D:owner>pwn<script></D:owner></D:lockinfo>';    # raw markup, must be neutralised

sub put_page {
    my ($s) = @_;
    run_dav( $s->{docroot}, 'PUT', '/content/p.md', body => "x", HTTP_AUTHORIZATION => $s->{auth} );
}
sub token_of { my ($r) = @_; ( $r->{headers}{'lock-token'} // '' ) =~ /<([^>]+)>/; return $1; }

# --- basic LOCK on an existing file -----------------------------------
{
    my $s = setup_dav_site();
    put_page($s);
    my $r = run_dav( $s->{docroot}, 'LOCK', '/content/p.md',
        body => $LOCKBODY, HTTP_AUTHORIZATION => $s->{auth} );
    is( $r->{code}, 200, 'LOCK existing => 200' );
    my $tok = token_of($r);
    like( $tok, qr/^opaquelocktoken:[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/,
        'lock token is opaquelocktoken: + v4 UUID' );
    like( $r->{body}, qr/<D:activelock>/, 'lockdiscovery body returned' );
    like( $r->{body}, qr/pwn&lt;script&gt;/, 'owner echoed with markup XML-escaped' );
    unlike( $r->{body}, qr/pwn<script>/, 'raw owner markup never echoed verbatim' );
    like( $r->{body}, qr/Second-\d+/, 'timeout reported' );
}

# --- LOCK while locked by another user => 423 -------------------------
{
    my $s = setup_dav_site();
    setup_other_user($s);
    put_page($s);
    run_dav( $s->{docroot}, 'LOCK', '/content/p.md', body => $LOCKBODY, HTTP_AUTHORIZATION => $s->{auth} );

    my $r = run_dav( $s->{docroot}, 'LOCK', '/content/p.md',
        body => $LOCKBODY, HTTP_AUTHORIZATION => $s->{other_auth} );
    is( $r->{code}, 423, 'LOCK on a resource locked by another user => 423' );
}

# --- shared lock requested => 403 -------------------------------------
{
    my $s = setup_dav_site();
    put_page($s);
    my $body = '<?xml version="1.0"?><D:lockinfo xmlns:D="DAV:">'
        . '<D:lockscope><D:shared/></D:lockscope>'
        . '<D:locktype><D:write/></D:locktype></D:lockinfo>';
    my $r = run_dav( $s->{docroot}, 'LOCK', '/content/p.md',
        body => $body, HTTP_AUTHORIZATION => $s->{auth} );
    is( $r->{code}, 403, 'shared lock refused' );
}

# --- Depth: infinity lock => 403 --------------------------------------
{
    my $s = setup_dav_site();
    put_page($s);
    my $r = run_dav( $s->{docroot}, 'LOCK', '/content/p.md',
        body => $LOCKBODY, HTTP_DEPTH => 'infinity', HTTP_AUTHORIZATION => $s->{auth} );
    is( $r->{code}, 403, 'Depth infinity lock refused' );
}

# --- LOCK an unmapped URL creates a locked empty resource -------------
{
    my $s = setup_dav_site();
    my $r = run_dav( $s->{docroot}, 'LOCK', '/content/fresh.md',
        body => $LOCKBODY, HTTP_AUTHORIZATION => $s->{auth} );
    is( $r->{code}, 201, 'LOCK unmapped => 201 (resource created)' );
    ok( -f "$s->{docroot}/content/fresh.md", 'empty resource created' );
    is( -s "$s->{docroot}/content/fresh.md", 0, 'created resource is empty' );
}

# --- LOCK unmapped but blocked/out-of-scope => 403, no file ------------
{
    my $s = setup_dav_site( scope => '/content' );
    my $r = run_dav( $s->{docroot}, 'LOCK', '/outside.md',
        body => $LOCKBODY, HTTP_AUTHORIZATION => $s->{auth} );
    is( $r->{code}, 403, 'LOCK unmapped out-of-scope => 403' );
    ok( !-e "$s->{docroot}/outside.md", 'no file created on refused lock' );
}

# --- refresh via If resets the clock ----------------------------------
{
    my $s = setup_dav_site();
    put_page($s);
    my $r = run_dav( $s->{docroot}, 'LOCK', '/content/p.md', body => $LOCKBODY, HTTP_AUTHORIZATION => $s->{auth} );
    my $tok = token_of($r);
    # Back-date the lock on disk so we can observe the refresh.
    my $lf = lockfile( $s, 'content/p.md' );
    backdate_lock( $lf, 200 );
    my $rf = run_dav( $s->{docroot}, 'LOCK', '/content/p.md',
        HTTP_IF => "(<$tok>)", HTTP_AUTHORIZATION => $s->{auth} );
    is( $rf->{code}, 200, 'refresh (empty body + If token) => 200' );
    my $age = time() - lock_at( $lf );
    ok( $age < 5, 'lock timestamp reset on refresh' );
}

# --- UNLOCK semantics --------------------------------------------------
{
    my $s = setup_dav_site();
    setup_other_user($s);
    put_page($s);
    my $r = run_dav( $s->{docroot}, 'LOCK', '/content/p.md', body => $LOCKBODY, HTTP_AUTHORIZATION => $s->{auth} );
    my $tok = token_of($r);

    my $missing = run_dav( $s->{docroot}, 'UNLOCK', '/content/p.md', HTTP_AUTHORIZATION => $s->{auth} );
    is( $missing->{code}, 400, 'UNLOCK without Lock-Token => 400' );

    my $wrong = run_dav( $s->{docroot}, 'UNLOCK', '/content/p.md',
        HTTP_LOCK_TOKEN => '<opaquelocktoken:nope>', HTTP_AUTHORIZATION => $s->{auth} );
    is( $wrong->{code}, 409, 'UNLOCK with wrong token => 409' );

    my $notowner = run_dav( $s->{docroot}, 'UNLOCK', '/content/p.md',
        HTTP_LOCK_TOKEN => "<$tok>", HTTP_AUTHORIZATION => $s->{other_auth} );
    is( $notowner->{code}, 403, 'UNLOCK by non-owner => 403' );

    my $ok = run_dav( $s->{docroot}, 'UNLOCK', '/content/p.md',
        HTTP_LOCK_TOKEN => "<$tok>", HTTP_AUTHORIZATION => $s->{auth} );
    is( $ok->{code}, 204, 'UNLOCK by owner => 204' );
}

# --- expired lock auto-clears -----------------------------------------
{
    my $s = setup_dav_site();
    put_page($s);
    my $r = run_dav( $s->{docroot}, 'LOCK', '/content/p.md', body => $LOCKBODY, HTTP_AUTHORIZATION => $s->{auth} );
    my $lf = lockfile( $s, 'content/p.md' );
    backdate_lock( $lf, 10_000 );    # far beyond any timeout
    # A write with no token should now succeed (lock expired).
    my $w = run_dav( $s->{docroot}, 'PUT', '/content/p.md', body => "y", HTTP_AUTHORIZATION => $s->{auth} );
    is( $w->{code}, 204, 'write succeeds once the lock has expired' );
}

# --- per-user lock flood guard ----------------------------------------
{
    my $s = setup_dav_site();
    # Pre-seed 100 fresh dav locks owned by the user.
    my $ld = "$s->{docroot}/lazysite/manager/locks";
    mkdir "$s->{docroot}/lazysite/manager"; mkdir $ld;
    require JSON::PP;
    for my $i ( 1 .. 100 ) {
        open my $fh, '>', "$ld/flood$i.lock" or die;
        print $fh JSON::PP::encode_json(
            { user => 'deploy', at => time(), origin => 'dav',
              token => "opaquelocktoken:x$i", timeout => 3600, owner => '' } );
        close $fh;
    }
    my $r = run_dav( $s->{docroot}, 'LOCK', '/content/another.md',
        body => $LOCKBODY, HTTP_AUTHORIZATION => $s->{auth} );
    is( $r->{code}, 503, '101st concurrent lock => 503' );
}

# --- helpers ----------------------------------------------------------
sub setup_other_user {
    my ($s) = @_;
    require TestHelper;
    TestHelper::dav_users_tool( $s->{docroot}, 'add', 'other', 'pw2' );
    TestHelper::grant_caps( $s->{docroot}, 'other', 'webdav', 'manage_content' );
    require MIME::Base64;
    $s->{other_auth} = 'Basic ' . MIME::Base64::encode_base64( 'other:pw2', '' );
}
sub lockfile {
    my ( $s, $rel ) = @_;
    ( my $key = $rel ) =~ s{/}{:}g;
    return "$s->{docroot}/lazysite/manager/locks/$key.lock";
}
sub backdate_lock {
    my ( $file, $secs ) = @_;
    require JSON::PP;
    open my $fh, '<', $file or die "no lock file $file";
    my $rec = JSON::PP::decode_json( do { local $/; <$fh> } );
    close $fh;
    $rec->{at} = time() - $secs;
    open my $w, '>', $file or die;
    print $w JSON::PP::encode_json($rec);
    close $w;
}
sub lock_at {
    my ($file) = @_;
    require JSON::PP;
    open my $fh, '<', $file or return 0;
    my $rec = JSON::PP::decode_json( do { local $/; <$fh> } );
    close $fh;
    return $rec->{at};
}

done_testing();
