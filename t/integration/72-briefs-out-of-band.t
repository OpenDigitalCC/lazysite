#!/usr/bin/perl
# SM245: briefs move out of band, into a store the plugin owns. The record
# SM073 invented survives; the sidecar file does not - and with it goes
# every engine rule that existed only because a brief was a file in the
# content tree. What stays, deliberately: the extension-level DENIES.
# Deployed sites carry unmigrated sidecars, and the processor's .brief 404
# is what keeps a stray one unserved once the engine is in the static path
# (t/integration/35's own finding) - so those rules outlive the feature as
# legacy-file protection, and this file asserts that too.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP   qw(decode_json encode_json);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root run_processor env_passthrough);

my $root    = repo_root();
my $docroot = tempdir( CLEANUP => 1 );
make_path("$docroot/lazysite/auth");
make_path("$docroot/content");
open my $cf, '>', "$docroot/lazysite/lazysite.conf" or die $!;
print {$cf} "site_name: T\n";
close $cf;
open my $pf, '>', "$docroot/content/page.md" or die $!;
print {$pf} "---\ntitle: P\n---\nx\n";
close $pf;

sub cgi_env {
    return ( env_passthrough(),
        DOCUMENT_ROOT         => $docroot,
        HTTP_X_REMOTE_USER    => 'author',
        LAZYSITE_AUTH_TRUSTED => 1,
        REMOTE_ADDR           => '127.0.0.1',
    );
}
sub api_get {
    my ($qs) = @_;
    local %ENV = ( cgi_env(), REQUEST_METHOD => 'GET', QUERY_STRING => $qs );
    my $out = qx($^X \Q$root/lazysite-manager-api.pl\E 2>/dev/null);
    $out =~ s/\A.*?\r?\n\r?\n//s;
    return eval { decode_json($out) } || { ok => 0, error => "unparseable: $out" };
}
my $TOKEN;
sub api_post {
    my ( $qs, $payload ) = @_;
    $TOKEN //= api_get('action=csrf-token')->{token};
    my $body = encode_json( $payload || {} );
    my $bf   = "$docroot/.body";
    open my $b, '>', $bf or die $!;
    print {$b} $body;
    close $b;
    local %ENV = ( cgi_env(),
        REQUEST_METHOD    => 'POST',
        QUERY_STRING      => $qs,
        CONTENT_TYPE      => 'application/json',
        CONTENT_LENGTH    => length $body,
        HTTP_X_CSRF_TOKEN => $TOKEN,
    );
    my $out = qx($^X \Q$root/lazysite-manager-api.pl\E < \Q$bf\E 2>/dev/null);
    $out =~ s/\A.*?\r?\n\r?\n//s;
    return eval { decode_json($out) } || { ok => 0, error => "unparseable: $out" };
}

subtest 'DISABLED MEANS DISABLED (ADR 0009, the SM469 clause)' => sub {
    my $r = api_get('action=brief-read&path=/content/page.md');
    ok( !$r->{ok}, 'a contract plugin executes nothing while disabled' );
    like( $r->{error} // '', qr/disabled|Plugin Manager/i, 'and says so' );
};

open my $ap, '>>', "$docroot/lazysite/lazysite.conf" or die $!;
print {$ap} "plugins:\n  - plugins/briefs.pl\n";
close $ap;

subtest 'the round trip: append, then read back, attributed and stamped' => sub {
    my $w = api_post( 'action=brief-append&path=/content/page.md',
        { entry => 'created the page for the launch' } );
    ok( $w->{ok}, 'append accepted' ) or diag explain $w;
    my $r = api_get('action=brief-read&path=/content/page.md');
    ok( $r->{ok} && $r->{exists}, 'read back' ) or diag explain $r;
    like( $r->{brief}, qr/created the page for the launch/, 'the entry' );
    like( $r->{brief}, qr/author/,                          'the author' );
    like( $r->{brief}, qr/\d{4}-\d{2}-\d{2}/,               'the date' );
    ok( -f "$docroot/lazysite/briefs/content/page.md",
        'held under lazysite/, engine-owned and never served' );
};

subtest 'MIGRATION: import, remove, idempotent, and never remove unimported' => sub {
    open my $sb, '>', "$docroot/content/old.md.brief" or die $!;
    print {$sb} "# Brief - old.md\nintent: legacy\n";
    close $sb;
    my $locked = "$docroot/content/locked.md.brief";
    open my $lb, '>', $locked or die $!;
    print {$lb} "unreachable\n";
    close $lb;
    chmod 0000, $locked;
    my $m = api_post( 'action=briefs-migrate', {} );
    ok( $m->{ok}, 'migration ran' ) or diag explain $m;
    is_deeply( $m->{imported}, ['content/old.md.brief'], 'the readable sidecar imported' );
    ok( !-e "$docroot/content/old.md.brief", 'and removed' );
    is( scalar @{ $m->{failed} }, 1, 'the unreadable one failed' );
    ok( -e $locked, 'AND WAS NOT REMOVED - never remove what was not imported' );
    chmod 0644, $locked;
    my $r = api_get('action=brief-read&path=/content/old.md');
    like( $r->{brief}, qr/legacy/, 'the imported record reads back under its file' );
    my $m2 = api_post( 'action=briefs-migrate', {} );
    is_deeply( $m2->{imported}, ['content/locked.md.brief'],
        'the second run imports only what the first could not - idempotent' );
    unlink $locked if -e $locked;

    # THE WRITE-FAILURE HALF of the hard rule, which the unreadable-sidecar
    # case cannot reach (its guard fires at the READ): a store that cannot be
    # written must leave the sidecar exactly where it was. The first sabotage
    # matrix proved this path untested - the unlink guard could be gutted and
    # nothing failed - so the case exists to make that sabotage bite.
    open my $wb, '>', "$docroot/content/unwritable.md.brief" or die $!;
    print {$wb} "must survive\n";
    close $wb;
    my $store_parent = "$docroot/lazysite/briefs/content";
    make_path($store_parent) unless -d $store_parent;
    chmod 0555, $store_parent;
    my $m3 = api_post( 'action=briefs-migrate', {} );
    chmod 0755, $store_parent;
    ok( -e "$docroot/content/unwritable.md.brief",
        'a sidecar whose import could not be WRITTEN is never removed' )
        or diag explain $m3;
    ok( ( grep { $_->{sidecar} eq 'content/unwritable.md.brief' } @{ $m3->{failed} || [] } ),
        'and is reported failed' );
    unlink "$docroot/content/unwritable.md.brief";
};

subtest 'THE DENIES OUTLIVE THE FEATURE - a stray sidecar is still unserved' => sub {
    open my $sb, '>', "$docroot/content/stray.md.brief" or die $!;
    print {$sb} "secret intent\n";
    close $sb;
    my $out = run_processor( $docroot, '/content/stray.md.brief' );
    like( $out, qr/Status:\s*404/, 'the processor still refuses .brief' )
        or diag( 'Deployed sites carry unmigrated sidecars; this 404 is what '
            . 'keeps one unserved once the engine is in the static path.' );
};

subtest 'SM504: A SIDECAR WRITE REFUSES ONCE THE STORE OWNS THE RECORD' => sub {
    # The operator's instruction: not an inert file - a refusal that names
    # the replacement. Gated on the PLUGIN (enabled above), never version.
    my $w = api_post( 'action=save&path=/content/late.md.brief',
        { content => "a note nobody would read\n", mtime => undef } );
    ok( !$w->{ok}, 'the manager/MCP write path refuses' ) or diag explain $w;
    like( $w->{error} // '', qr/append_brief|brief-append/,
        'and names the replacement (SM228 shape)' );
    ok( !-e "$docroot/content/late.md.brief", 'nothing landed' );

    # And the DAV channel refuses the same way - the first build of this
    # subtest never covered DAV, and the wire there had silently failed to
    # apply; this case is what makes that impossible to miss again.
    require MIME::Base64;
    my $dav_body = "why: because\n";
    my $dbf      = "$docroot/.davbody";
    open my $db, '>', $dbf or die $!;
    print {$db} $dav_body;
    close $db;
    open my $wc, '>>', "$docroot/lazysite/lazysite.conf" or die $!;
    print {$wc} "webdav_enabled: true\n";
    close $wc;
    # TestHelper's proven pair: the account, then a role group WITH the user
    # as a member (the hand-rolled version granted the group and never joined
    # the user - a 403 from the capability layer, not the wire under test).
    TestHelper::dav_users_tool( $docroot, 'add', 'davpub', 'pw123456789' );
    TestHelper::grant_caps( $docroot, 'davpub', qw(webdav manage_content) );
    {
        local %ENV = ( %ENV,
            DOCUMENT_ROOT      => $docroot,
            SCRIPT_NAME        => '/dav',
            REMOTE_ADDR        => '127.0.0.1',
            REQUEST_METHOD     => 'PUT',
            PATH_INFO          => '/content/over-dav.md.brief',
            CONTENT_LENGTH     => length $dav_body,
            HTTP_AUTHORIZATION => 'Basic '
                . MIME::Base64::encode_base64( 'davpub:pw123456789', '' ),
        );
        my $out = qx(sh -c \Q$^X \Q$root/lazysite-dav.pl\E < \Q$dbf\E 2>/dev/null\E);
        like( $out, qr/Status: 415/, 'the DAV channel refuses too' ) or diag "[$out]";
        like( $out, qr/append_brief|brief-append/, 'naming the replacement there as well' );
        ok( !-e "$docroot/content/over-dav.md.brief", 'nothing landed over DAV' );
    }

    # B4: reading an existing sidecar still works - an agent can see what is
    # there before migrating it.
    open my $old, '>', "$docroot/content/pre.md.brief" or die $!;
    print {$old} "written before the store\n";
    close $old;
    my $r = api_get('action=read&path=/content/pre.md.brief');
    ok( $r->{ok}, 'an existing sidecar is still readable' ) or diag explain $r;
    unlink "$docroot/content/pre.md.brief";
};

subtest 'SM504-B3: A SITE STILL ON SIDECARS KEEPS WORKING, INDEFINITELY' => sub {
    # Migration is per site, as each is revisited - a half-migrated estate is
    # the normal state. The refusal is a consequence of the store existing on
    # THIS site, never of the version number.
    my $other = tempdir( CLEANUP => 1 );
    make_path("$other/lazysite/auth");
    make_path("$other/content");
    open my $cf2, '>', "$other/lazysite/lazysite.conf" or die $!;
    print {$cf2} "site_name: Legacy\n";    # briefs plugin NOT enabled
    close $cf2;
    local %ENV = ( cgi_env(), DOCUMENT_ROOT => $other,
        REQUEST_METHOD => 'GET', QUERY_STRING => 'action=csrf-token' );
    my $out = qx($^X \Q$root/lazysite-manager-api.pl\E 2>/dev/null);
    $out =~ s/\A.*?\r?\n\r?\n//s;
    my $tok  = ( eval { decode_json($out) } || {} )->{token};
    my $body = encode_json( { content => "still the right file here\n", mtime => undef } );
    my $bf   = "$other/.body";
    open my $b, '>', $bf or die $!;
    print {$b} $body;
    close $b;
    local %ENV = ( cgi_env(), DOCUMENT_ROOT => $other,
        REQUEST_METHOD    => 'POST',
        QUERY_STRING      => 'action=save&path=/content/note.md.brief',
        CONTENT_TYPE      => 'application/json',
        CONTENT_LENGTH    => length $body,
        HTTP_X_CSRF_TOKEN => $tok );
    my $out2 = qx($^X \Q$root/lazysite-manager-api.pl\E < \Q$bf\E 2>/dev/null);
    $out2 =~ s/\A.*?\r?\n\r?\n//s;
    my $w = eval { decode_json($out2) } || {};
    ok( $w->{ok}, 'a sidecar still writes on an unmigrated site' ) or diag explain $w;
    ok( -f "$other/content/note.md.brief", 'and lands as the working record it still is' );
};

subtest 'SM507: THE STORE ENTRY FOLLOWS ITS FILE, on every surface' => sub {
    # SM245 recorded the rename gap as "a tolerable interim until a reconcile
    # adopts it". The field found the cost first: a renamed page silently
    # split from its record of intent, and a deleted page's entry orphaned
    # where nothing can list it. This is the reconcile.
    my $store = "$docroot/lazysite/briefs";

    # Manager/MCP surface: move carries, delete removes.
    api_post( 'action=save&path=/content/m1.md',
        { content => "---\ntitle: M\n---\nx\n", mtime => undef } );
    api_post( 'action=brief-append&path=/content/m1.md',
        { entry => 'born briefed' } );
    ok( -f "$store/content/m1.md", 'the entry exists under the old key' );
    my $mv = api_post( 'action=move&path=/content/m1.md&to=/content/m2.md', {} );
    ok( $mv->{ok},                  'moved' ) or diag explain $mv;
    ok( -f "$store/content/m2.md",  'the entry followed the rename' );
    ok( !-e "$store/content/m1.md", 'and left the old key' );
    my $rd = api_get('action=brief-read&path=/content/m2.md');
    ok( $rd->{ok} && $rd->{exists}, 'the renamed page still answers its brief' )
        or diag explain $rd;
    my $del = api_post( 'action=delete&path=/content/m2.md', {} );
    ok( $del->{ok},                 'deleted' ) or diag explain $del;
    ok( !-e "$store/content/m2.md", 'the entry went with the file' );

    # DAV surface: same promise, own process (the docroot rides as a
    # parameter - this process never sets the package var).
    require MIME::Base64;
    api_post( 'action=save&path=/content/d1.md',
        { content => "---\ntitle: D\n---\nx\n", mtime => undef } );
    api_post( 'action=brief-append&path=/content/d1.md',
        { entry => 'dav-bound' } );
    ok( -f "$store/content/d1.md", 'entry in place before the DAV move' );
    my %dav = (
        DOCUMENT_ROOT      => $docroot,
        SCRIPT_NAME        => '/dav',
        REMOTE_ADDR        => '127.0.0.1',
        CONTENT_LENGTH     => 0,
        HTTP_AUTHORIZATION => 'Basic '
            . MIME::Base64::encode_base64( 'davpub:pw123456789', '' ),
    );
    {
        local %ENV = ( %ENV, %dav,
            REQUEST_METHOD   => 'MOVE',
            PATH_INFO        => '/content/d1.md',
            HTTP_DESTINATION => '/dav/content/d2.md',
        );
        my $out = qx($^X \Q$root/lazysite-dav.pl\E 2>/dev/null);
        like( $out, qr/Status: 20[14]/, 'DAV MOVE succeeded' ) or diag "[$out]";
    }
    ok( -f "$store/content/d2.md",  'the entry followed the DAV move' );
    ok( !-e "$store/content/d1.md", 'and left the old key there too' );
    {
        local %ENV = ( %ENV, %dav,
            REQUEST_METHOD => 'DELETE',
            PATH_INFO      => '/content/d2.md',
        );
        my $out = qx($^X \Q$root/lazysite-dav.pl\E 2>/dev/null);
        like( $out, qr/Status: 204/, 'DAV DELETE succeeded' ) or diag "[$out]";
    }
    ok( !-e "$store/content/d2.md", 'the entry went with the DAV delete' );
};

done_testing();
