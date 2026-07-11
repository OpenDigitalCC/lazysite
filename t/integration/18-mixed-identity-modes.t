#!/usr/bin/perl
# Split-identity invariant (field 2026-07-11): on a group-shared docroot,
# whichever identity acts FIRST must never lock the other out.
#   - TT creates its compile-cache dirs with the process umask; the processor
#     now scopes umask 0002 around the compile-cache surfaces, so a render
#     under a hostile 0022 umask still leaves cache/tt group-writable.
#   - Cached .html files come out group-writable too (refreshes go through
#     rename, but both identities must be able to manage the entries).
#   - Minted secrets (auth/.secret & friends) are created 0660 - owner+group,
#     NEVER world - so a CLI-context mint no longer 500s the www-data CGI's
#     cookie verification (and vice versa).
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Find ();
use IPC::Open3;
use Symbol qw(gensym);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root setup_test_site run_processor env_passthrough);

my $root = repo_root();
my $d    = tempdir( CLEANUP => 1 );
setup_test_site($d);

my $old_umask = umask 0022;    # the hostile-but-usual umask from the field
END { umask $old_umask if defined $old_umask }

# --- render under umask 0022 -------------------------------------------------
my $out = run_processor( $d, '/index' );
like( $out, qr/Home|Test/i, 'page rendered' );

subtest 'cache/tt dirs are group-writable despite umask 0022' => sub {
    my $tt = "$d/lazysite/cache/tt";
    plan skip_all => 'no compile cache written (TT built without COMPILE_DIR?)'
        unless -d $tt;
    my @bad;
    File::Find::find(
        { no_chdir => 1, wanted => sub {
                return unless -d $File::Find::name;
                my $m = ( stat _ )[2] & 07777;
                push @bad, sprintf( '%s (%04o)', $File::Find::name, $m )
                    unless $m & 0020;
        } }, $tt );
    ok( !@bad, 'every compile-cache dir carries group-write' )
        or diag join "\n", @bad;
};

subtest 'cached .html is group-writable despite umask 0022' => sub {
    my @html;
    File::Find::find(
        { no_chdir => 1, wanted => sub {
                push @html, $File::Find::name if /\.html\z/ && -f;
        } }, $d );
    plan skip_all => 'no cached html produced' unless @html;
    for my $h (@html) {
        my $m = ( stat $h )[2] & 07777;
        ok( $m & 0020, sprintf( '%s group-writable (%04o)', $h =~ s{^\Q$d/\E}{}r, $m ) );
    }
};

# --- secret mint under umask 0022: auth/.secret via a login ------------------
subtest 'auth secret minted 0660 (owner+group, never world)' => sub {
    require JSON::PP;
    require IPC::Open2;
    my $utl = "$root/tools/lazysite-users.pl";

    # seed a user through the tool (API mode, like the real CGI does)
    my ( $cout, $cin );
    my $pid = IPC::Open2::open2( $cout, $cin, $^X, $utl, '--api', '--docroot', $d );
    print $cin JSON::PP::encode_json( { action => 'add', username => 'u1', password => 'pw' } );
    close $cin;
    do { local $/; <$cout> };
    waitpid $pid, 0;

    # a login mints lazysite/auth/.secret if absent
    my $body = 'username=u1&password=pw&next=/';
    local %ENV = ( env_passthrough(),
        DOCUMENT_ROOT       => $d,
        REMOTE_ADDR         => '127.0.0.1',
        HTTPS               => '',
        REQUEST_METHOD      => 'POST',
        QUERY_STRING        => 'action=login',
        CONTENT_LENGTH      => length($body),
        CONTENT_TYPE        => 'application/x-www-form-urlencoded',
        LAZYSITE_USERS_TOOL => $utl,
    );
    my $err = gensym;
    my $apid = open3( my $wtr, my $rdr, $err, $^X, "$root/lazysite-auth.pl" );
    print $wtr $body;
    close $wtr;
    do { local $/; <$rdr> };
    do { local $/; <$err> };
    waitpid $apid, 0;

    my $sec = "$d/lazysite/auth/.secret";
    ok( -f $sec, 'auth/.secret minted by the login flow' ) or return;
    my $m = ( stat $sec )[2] & 07777;
    is( $m, 0660, sprintf( 'auth/.secret is exactly 0660 (got %04o)', $m ) );

    # every OTHER minted secret that exists must be 0660 too, never world
    for my $rel ( qw(
        lazysite/forms/.secret lazysite/manager/.csrf-secret
        lazysite/auth/oauth.json lazysite/logs/.access-salt
        ) ) {
        next unless -f "$d/$rel";
        my $sm = ( stat "$d/$rel" )[2] & 07777;
        is( $sm, 0660, "$rel is 0660" );
    }
};

done_testing();
