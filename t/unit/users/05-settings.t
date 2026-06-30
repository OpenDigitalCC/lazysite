#!/usr/bin/perl
# SM070: per-user access-mechanism settings in tools/lazysite-users.pl.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use JSON::PP qw(encode_json decode_json);
use IPC::Open2;
use IPC::Open3;
use Symbol qw(gensym);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root grant_caps);

my $root   = repo_root();
my $script = "$root/tools/lazysite-users.pl";

sub fresh_docroot {
    my $d = tempdir( CLEANUP => 1 );
    mkdir "$d/lazysite";
    mkdir "$d/lazysite/auth";
    # Per-user webdav now requires WebDAV enabled site-wide.
    open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
    print $cf "webdav_enabled: enabled\n";
    close $cf;
    return $d;
}

# Run the tool in CLI mode, capturing stdout, stderr, and exit code.
sub cli {
    my ( $docroot, @args ) = @_;
    my ( $wtr, $rdr );
    my $err = gensym;
    my $pid = open3( $wtr, $rdr, $err, $^X, $script, '--docroot', $docroot, @args );
    close $wtr;
    my $out = do { local $/; <$rdr> };
    my $eout = do { local $/; <$err> };
    waitpid $pid, 0;
    return { out => $out // '', err => $eout // '', code => $? >> 8 };
}

sub api {
    my ( $docroot, $payload ) = @_;
    my ( $cout, $cin );
    my $pid = open2( $cout, $cin, $^X, $script, '--api', '--docroot', $docroot );
    print $cin encode_json($payload);
    close $cin;
    my $out = do { local $/; <$cout> };
    close $cout;
    waitpid $pid, 0;
    return eval { decode_json($out) } // { _raw => $out };
}

# --- defaults when nothing is set --------------------------------------
{
    my $d = fresh_docroot();
    cli( $d, 'add', 'alice', 'pw' );

    my $r = api( $d, { action => 'settings-get', username => 'alice' } );
    is( $r->{ok}, 1, 'settings-get ok for user with no settings row' );
    ok( !$r->{settings}{webdav}, 'webdav defaults off' );
    ok( $r->{settings}{ui},      'ui defaults on' );
    ok( !defined $r->{settings}{dav_scope}, 'dav_scope defaults unset (null)' );

    ok( !-f "$d/lazysite/auth/user-settings.json",
        'no settings file written just by reading defaults' );
}

# --- set / get round-trip ---------------------------------------------
{
    my $d = fresh_docroot();
    cli( $d, 'add', 'deploy', 'pw' );
    grant_caps( $d, 'deploy', 'webdav' );
    cli( $d, 'set', 'deploy', 'dav_scope', '/content' );

    my $r = api( $d, { action => 'settings-get', username => 'deploy' } );
    ok( $r->{settings}{webdav}, 'webdav now on' );
    is( $r->{settings}{dav_scope}, '/content', 'scope round-trips' );
    ok( $r->{settings}{ui}, 'ui still defaults on (untouched)' );

    # analytics capability (visitor stats + audit): off by default, settable on.
    ok( !$r->{settings}{analytics}, 'analytics defaults off' );
    grant_caps( $d, 'deploy', 'analytics' );
    my $r2 = api( $d, { action => 'settings-get', username => 'deploy' } );
    ok( $r2->{settings}{analytics}, 'analytics now on after set' );

    # file is valid JSON keyed by username
    open my $fh, '<', "$d/lazysite/auth/user-settings.json" or die;
    my $data = decode_json( do { local $/; <$fh> } );
    close $fh;
    ok( exists $data->{deploy}, 'settings file keyed by username' );
}

# --- on/off parsing and clearing scope --------------------------------
{
    my $d = fresh_docroot();
    cli( $d, 'add', 'u', 'pw' );

    my $bad = cli( $d, 'set', 'u', 'webdav', 'maybe' );
    isnt( $bad->{code}, 0, 'invalid on/off value is rejected' );

    cli( $d, 'set', 'u', 'dav_scope', '/content/' );    # trailing slash
    my $r = api( $d, { action => 'settings-get', username => 'u' } );
    is( $r->{settings}{dav_scope}, '/content', 'trailing slash normalised away' );

    cli( $d, 'set', 'u', 'dav_scope', '' );             # clear
    $r = api( $d, { action => 'settings-get', username => 'u' } );
    ok( !defined $r->{settings}{dav_scope}, 'empty value clears scope' );

    cli( $d, 'set', 'u', 'dav_scope', '/' );            # root = unset
    $r = api( $d, { action => 'settings-get', username => 'u' } );
    ok( !defined $r->{settings}{dav_scope}, 'root scope is treated as unset' );

    my $trav = cli( $d, 'set', 'u', 'dav_scope', '/a/../b' );
    isnt( $trav->{code}, 0, 'traversal in scope rejected' );

    my $badkey = cli( $d, 'set', 'u', 'nonsense', 'on' );
    isnt( $badkey->{code}, 0, 'unknown setting key rejected' );
}

# --- corrupt JSON => defaults + warning -------------------------------
{
    my $d = fresh_docroot();
    cli( $d, 'add', 'alice', 'pw' );
    open my $fh, '>', "$d/lazysite/auth/user-settings.json" or die;
    print $fh "{ this is not json";
    close $fh;

    my $res = cli( $d, 'settings', 'alice' );
    like( $res->{out}, qr/webdav:\s+off/, 'corrupt file falls back to webdav off' );
    like( $res->{out}, qr/ui:\s+on/,      'corrupt file falls back to ui on' );
    like( $res->{err}, qr/unparseable/i,  'WARN logged about unparseable file' );
}

# --- remove clears the settings entry ---------------------------------
{
    my $d = fresh_docroot();
    cli( $d, 'add', 'gone', 'pw' );
    grant_caps( $d, 'gone', 'webdav' );
    cli( $d, 'add', 'stay', 'pw' );
    grant_caps( $d, 'stay', 'webdav' );

    cli( $d, 'remove', 'gone' );

    # Capabilities live on groups now, so removal must drop the user from group
    # membership (where their access lived).
    open my $fh, '<', "$d/lazysite/auth/groups" or die;
    my $groups = do { local $/; <$fh> };
    close $fh;
    unlike( $groups, qr/\bgone\b/, 'removed user dropped from all groups' );
    like( $groups, qr/\bstay\b/, 'other users group membership preserved' );
}

# --- last-manager-UI guard --------------------------------------------
{
    my $d = fresh_docroot();
    # No manager_groups set => any user is manager-capable.
    cli( $d, 'add', 'alice', 'pw' );
    cli( $d, 'add', 'bob',   'pw' );

    # Two users with ui on: disabling one is fine.
    my $ok1 = cli( $d, 'set', 'alice', 'ui', 'off' );
    is( $ok1->{code}, 0, 'ui off allowed while another UI account remains' );

    # bob is now the last UI account: refuse.
    my $refused = cli( $d, 'set', 'bob', 'ui', 'off' );
    isnt( $refused->{code}, 0, 'ui off refused for the last manager-capable account' );
    like( $refused->{err} . $refused->{out}, qr/last manager-capable/i,
        'guard message explains why' );

    # --force overrides.
    my $forced = cli( $d, 'set', 'bob', 'ui', 'off', '--force' );
    is( $forced->{code}, 0, '--force overrides the guard' );
}

# --- guard scoped to manager_groups membership ------------------------
{
    my $d = fresh_docroot();
    open my $cf, '>', "$d/lazysite/lazysite.conf" or die;
    print $cf "manager_groups: admins\n";
    close $cf;

    cli( $d, 'add', 'admin1', 'pw' );
    cli( $d, 'add', 'editor', 'pw' );
    cli( $d, 'group-add', 'admin1', 'admins' );

    # editor is not in admins, so admin1 is the only manager-capable UI
    # account: disabling admin1's ui is refused, editor's is allowed.
    my $refuse = cli( $d, 'set', 'admin1', 'ui', 'off' );
    isnt( $refuse->{code}, 0, 'last admin UI account is protected' );

    my $allow = cli( $d, 'set', 'editor', 'ui', 'off' );
    is( $allow->{code}, 0, 'non-manager account ui can be disabled freely' );
}

done_testing();
