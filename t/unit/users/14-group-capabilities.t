#!/usr/bin/perl
# SM095 Phase 1: capabilities carried by GROUPS; members inherit the union.
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
use TestHelper qw(repo_root);

my $script = repo_root() . '/tools/lazysite-users.pl';

sub docroot {
    my $d = tempdir( CLEANUP => 1 );
    mkdir "$d/lazysite"; mkdir "$d/lazysite/auth";
    open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
    print $cf "manager_groups: lazysite-admins\n";
    close $cf;
    return $d;
}

sub cli {
    my ( $d, @a ) = @_;
    my ( $wtr, $rdr ); my $err = gensym;
    my $pid = open3( $wtr, $rdr, $err, $^X, $script, '--docroot', $d, @a );
    close $wtr;
    my $out = do { local $/; <$rdr> }; my $e = do { local $/; <$err> };
    waitpid $pid, 0;
    return { out => $out // '', err => $e // '', code => $? >> 8 };
}

sub caps {
    my ( $d, $user ) = @_;
    my ( $o, $i );
    my $pid = open2( $o, $i, $^X, $script, '--api', '--docroot', $d );
    print $i encode_json( { action => 'settings-get', username => $user } );
    close $i;
    my $out = do { local $/; <$o> }; close $o; waitpid $pid, 0;
    return ( eval { decode_json($out) } || {} )->{settings} || {};
}

# A role group grants exactly its capabilities to members.
{
    my $d = docroot();
    cli( $d, 'add', 'ada', 'pw' );
    cli( $d, 'group-add', 'ada', 'content-editors' );
    my $s = caps( $d, 'ada' );
    ok( $s->{manage_content}, 'content-editors grants manage_content' );
    ok( $s->{manage_nav},     'content-editors grants manage_nav' );
    ok( $s->{manage_forms},   'content-editors grants manage_forms' );
    ok( !$s->{manage_themes}, 'content-editors does NOT grant manage_themes' );
    ok( !$s->{analytics},     'content-editors does NOT grant analytics' );
    is_deeply( $s->{groups}, ['content-editors'], 'effective settings lists the membership' );
}

# Multiple groups COMPOUND (union of capabilities).
{
    my $d = docroot();
    cli( $d, 'add', 'mix', 'pw' );
    cli( $d, 'group-add', 'mix', 'content-editors' );
    cli( $d, 'group-add', 'mix', 'design-team' );
    my $s = caps( $d, 'mix' );
    ok( $s->{manage_content}, 'union: content from content-editors' );
    ok( $s->{manage_themes},  'union: themes from design-team' );
    ok( $s->{manage_layouts}, 'union: layouts from design-team' );
}

# The seeded agent-ai group carries the analytics capability.
{
    my $d = docroot();
    cli( $d, 'add', 'bot', 'pw' );
    cli( $d, 'group-add', 'bot', 'agent-ai' );
    my $s = caps( $d, 'bot' );
    ok( $s->{analytics}, 'agent-ai grants analytics' );
    ok( $s->{webdav},    'agent-ai grants webdav' );
}

# lazysite-admins is seeded as a MANAGER group with full capabilities (so the
# operator keeps manager + partner access after the clean cut).
{
    my $d = docroot();
    cli( $d, 'add', 'boss', 'pw' );
    cli( $d, 'group-add', 'boss', 'lazysite-admins' );
    my $s = caps( $d, 'boss' );
    ok( $s->{manage_config}, 'admins group grants manage_config' );
    ok( $s->{analytics},     'admins group grants analytics' );
    ok( $s->{create_sub_users}, 'admins group grants create_sub_users' );

    open my $gf, '<', "$d/lazysite/auth/groups-settings.json" or die $!;
    my $gs = decode_json( do { local $/; <$gf> } );
    close $gf;
    ok( $gs->{'lazysite-admins'}{manager}, 'lazysite-admins flagged as a manager group' );
    ok( exists $gs->{'user-managers'}, 'default role groups were seeded' );
}

sub api {
    my ( $d, $payload ) = @_;
    my ( $o, $i );
    my $pid = open2( $o, $i, $^X, $script, '--api', '--docroot', $d );
    print $i encode_json($payload);
    close $i;
    my $out = do { local $/; <$o> }; close $o; waitpid $pid, 0;
    return eval { decode_json($out) } || {};
}

# Phase 2 backend: edit a group's capabilities; create and delete groups.
{
    my $d = docroot();
    cli( $d, 'add', 'u', 'pw' );
    cli( $d, 'group-add', 'u', 'content-editors' );
    is( api( $d, { action => 'group-settings-set', group => 'content-editors', key => 'analytics', value => 'on' } )->{ok},
        1, 'set analytics on content-editors' );
    ok( caps( $d, 'u' )->{analytics}, 'member inherits the newly-granted capability' );

    is( api( $d, { action => 'group-create', group => 'editors' } )->{ok}, 1, 'create a group' );
    ok( exists api( $d, { action => 'group-settings-get' } )->{groups}{editors},
        'created group shows in the unified view' );
    is( api( $d, { action => 'group-delete', group => 'editors' } )->{ok}, 1, 'delete a group' );

    my $bad = api( $d, { action => 'group-delete', group => 'lazysite-admins' } );
    ok( !$bad->{ok}, 'cannot delete the only manager group (lockout guard)' );
    my $bad2 = api( $d, { action => 'group-settings-set', group => 'lazysite-admins', key => 'manager', value => 'off' } );
    ok( !$bad2->{ok}, 'cannot clear manager from the only manager group' );
}

# Phase (b): new channel caps (ui/api/mcp) + manage_users; the permissions grid.
{
    my $d = docroot();
    cli( $d, 'add', 'um', 'pw' );
    cli( $d, 'group-add', 'um', 'user-managers' );
    my $s = caps( $d, 'um' );
    ok( $s->{manage_users}, 'user-managers grants manage_users' );
    ok( $s->{ui},           'user-managers grants the ui channel' );
    ok( !$s->{webdav},      'user-managers does NOT grant webdav' );

    cli( $d, 'add', 'mc', 'pw' );
    cli( $d, 'group-add', 'mc', 'mcp-ai' );
    my $g = api( $d, { action => 'permissions-grid', username => 'mc' } );
    ok( $g->{ok}, 'permissions-grid ok' );
    is_deeply( $g->{channels}, [qw(ui webdav api mcp)], 'grid lists the four channels' );
    ok( ( grep { $_ eq 'mcp-ai' } @{ $g->{granted_by}{mcp} || [] } ),
        'mcp channel granted by mcp-ai' );
    ok( ( grep { $_ eq 'mcp-ai' } @{ $g->{granted_by}{manage_content} || [] } ),
        'content action granted by mcp-ai' );
    ok( !@{ $g->{granted_by}{ui} || [] }, 'mcp-ai does not grant the ui channel' );
}

# Phase 1 is non-breaking: a legacy per-user grant still resolves on.
{
    my $d = docroot();
    cli( $d, 'add', 'legacy', 'pw' );
    cli( $d, 'set', 'legacy', 'analytics', 'on' );    # per-user grant, no group
    my $s = caps( $d, 'legacy' );
    ok( $s->{analytics}, 'a legacy per-user grant still applies (union)' );
}

done_testing;
