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
    cli( $d, 'group-add', 'ada', 'content-manager' );
    my $s = caps( $d, 'ada' );
    ok( $s->{manage_content}, 'content-manager grants manage_content' );
    ok( $s->{manage_nav},     'content-manager grants manage_nav' );
    ok( $s->{manage_forms},   'content-manager grants manage_forms' );
    ok( !$s->{manage_themes}, 'content-manager does NOT grant manage_themes' );
    ok( !$s->{analytics},     'content-manager does NOT grant analytics' );
    is_deeply( $s->{groups}, ['content-manager'], 'effective settings lists the membership' );
}

# Multiple groups COMPOUND (union of capabilities).
{
    my $d = docroot();
    cli( $d, 'add', 'mix', 'pw' );
    cli( $d, 'group-add', 'mix', 'content-manager' );
    cli( $d, 'group-add', 'mix', 'appearance-manager' );
    my $s = caps( $d, 'mix' );
    ok( $s->{manage_content}, 'union: content from content-manager' );
    ok( $s->{manage_themes},  'union: themes from appearance-manager' );
    ok( $s->{manage_layouts}, 'union: layouts from appearance-manager' );
}

# The seeded ai-site-manager group carries the analytics capability.
{
    my $d = docroot();
    cli( $d, 'add', 'bot', 'pw' );
    cli( $d, 'group-add', 'bot', 'ai-site-manager' );
    my $s = caps( $d, 'bot' );
    ok( $s->{analytics}, 'ai-site-manager grants analytics' );
    ok( $s->{webdav},    'ai-site-manager grants webdav' );
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
    ok( exists $gs->{'user-manager'}, 'default role groups were seeded' );
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
