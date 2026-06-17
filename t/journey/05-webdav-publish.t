#!/usr/bin/perl
# SM070 journey: the full WebDAV publishing lifecycle, end to end.
#   create user -> enable webdav + scope -> generate credential ->
#   publish with the credential -> page renders -> scope enforced ->
#   LOCK / PUT(If) / UNLOCK cycle -> a manager lock blocks DAV writes ->
#   disable webdav -> writes refused -> regenerating the credential
#   invalidates the previous one.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use MIME::Base64 qw(encode_base64);
use JSON::PP qw(encode_json decode_json);
use IPC::Open2;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root run_dav run_processor setup_minimal_site dav_users_tool);

my $root    = repo_root();
my $docroot = tempdir( CLEANUP => 1 );
setup_minimal_site($docroot);
make_path("$docroot/lazysite/auth");
open my $cf, '>>', "$docroot/lazysite/lazysite.conf" or die $!;
print $cf "webdav_enabled: true\n";
close $cf;

sub users_api {
    my ($payload) = @_;
    my ( $cout, $cin );
    my $pid = open2( $cout, $cin, $^X, "$root/tools/lazysite-users.pl",
        '--api', '--docroot', $docroot );
    print $cin encode_json($payload);
    close $cin;
    my $out = do { local $/; <$cout> };
    close $cout;
    waitpid $pid, 0;
    return decode_json($out);
}
sub basic { 'Basic ' . encode_base64( "deploy:$_[0]", '' ) }

# --- provision a publishing account -----------------------------------
dav_users_tool( $docroot, 'add', 'deploy', 'initial-pw' );
dav_users_tool( $docroot, 'set', 'deploy', 'webdav', 'on' );
dav_users_tool( $docroot, 'set', 'deploy', 'dav_scope', '/content' );
make_path("$docroot/content");

my $tok1 = users_api( { action => 'token', username => 'deploy' } )->{token};
like( $tok1, qr/^lzs_/, 'generated a credential' );

# --- publish with the credential --------------------------------------
{
    my $r = run_dav( $docroot, 'PUT', '/content/page.md',
        body => "---\ntitle: P\n---\nHELLO-DAV\n", HTTP_AUTHORIZATION => basic($tok1) );
    is( $r->{code}, 201, 'publish with generated credential => 201' );

    my $out = run_processor( $docroot, '/content/page' );
    like( $out, qr/HELLO-DAV/, 'published page renders through the processor' );
}

# --- scope is enforced -------------------------------------------------
{
    my $r = run_dav( $docroot, 'PUT', '/index.md',
        body => "x", HTTP_AUTHORIZATION => basic($tok1) );
    is( $r->{code}, 403, 'write outside /content scope refused' );
}

# --- LOCK / PUT(If) / UNLOCK cycle -------------------------------------
{
    my $lockbody = '<?xml version="1.0"?><D:lockinfo xmlns:D="DAV:">'
        . '<D:lockscope><D:exclusive/></D:lockscope>'
        . '<D:locktype><D:write/></D:locktype></D:lockinfo>';
    my $lr = run_dav( $docroot, 'LOCK', '/content/page.md',
        body => $lockbody, HTTP_AUTHORIZATION => basic($tok1) );
    is( $lr->{code}, 200, 'LOCK => 200' );
    my ($tok) = ( $lr->{headers}{'lock-token'} // '' ) =~ /<([^>]+)>/;

    # The lock lives in the shared manager lock store, as a JSON record.
    my $lf = "$docroot/lazysite/manager/locks/content:page.md.lock";
    ok( -f $lf, 'lock recorded in the shared manager lock store' );
    open my $fh, '<', $lf; my $rec = decode_json( do { local $/; <$fh> } ); close $fh;
    is( $rec->{origin}, 'dav', 'lock record marked dav-origin' );

    my $no = run_dav( $docroot, 'PUT', '/content/page.md',
        body => "blocked", HTTP_AUTHORIZATION => basic($tok1) );
    is( $no->{code}, 423, 'write without the lock token => 423' );

    my $yes = run_dav( $docroot, 'PUT', '/content/page.md',
        body => "---\ntitle: P\n---\nLOCKED-WRITE\n",
        HTTP_IF => "(<$tok>)", HTTP_AUTHORIZATION => basic($tok1) );
    is( $yes->{code}, 204, 'write carrying the lock token => 204' );

    my $ul = run_dav( $docroot, 'UNLOCK', '/content/page.md',
        HTTP_LOCK_TOKEN => "<$tok>", HTTP_AUTHORIZATION => basic($tok1) );
    is( $ul->{code}, 204, 'UNLOCK => 204' );
}

# --- a manager editor lock blocks DAV writes --------------------------
{
    # Simulate the manager editor holding the lock (legacy line format).
    my $lf = "$docroot/lazysite/manager/locks/content:page.md.lock";
    open my $w, '>', $lf or die; print $w "alice " . time(); close $w;

    my $r = run_dav( $docroot, 'PUT', '/content/page.md',
        body => "x", HTTP_AUTHORIZATION => basic($tok1) );
    is( $r->{code}, 423, 'manager-held lock blocks the DAV write' );
    unlink $lf;
}

# --- disabling webdav refuses all writes ------------------------------
{
    dav_users_tool( $docroot, 'set', 'deploy', 'webdav', 'off' );
    my $r = run_dav( $docroot, 'PUT', '/content/page.md',
        body => "x", HTTP_AUTHORIZATION => basic($tok1) );
    is( $r->{code}, 403, 'webdav disabled => writes refused' );
    dav_users_tool( $docroot, 'set', 'deploy', 'webdav', 'on' );
}

# --- regenerating the credential invalidates the previous one ---------
{
    my $tok2 = users_api( { action => 'token', username => 'deploy' } )->{token};
    isnt( $tok2, $tok1, 'second credential differs' );

    my $old = run_dav( $docroot, 'PUT', '/content/page.md',
        body => "x", HTTP_AUTHORIZATION => basic($tok1) );
    is( $old->{code}, 401, 'old credential no longer authenticates' );

    my $new = run_dav( $docroot, 'PUT', '/content/page.md',
        body => "---\ntitle: P\n---\nNEW-CRED\n", HTTP_AUTHORIZATION => basic($tok2) );
    is( $new->{code}, 204, 'new credential works' );
}

done_testing();
