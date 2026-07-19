#!/usr/bin/perl
# ADVERSARIAL (SEC-2026-07 C1 defence-in-depth, 0.8.1): the capability/group-
# mutating verbs (add, remove, group-add/-remove, group-settings-set,
# group-create/-delete/-nest, settings-set, token) are confined at the manager-
# API CGI by omission from %DELEGABLE. This test pins the TOOL-level backstop:
# driven directly with a NON-OPERATOR actor, the tool refuses the verb itself -
# so a delegate cannot escalate even if some future surface forwards the call.
# With no actor (CLI/operator context) or an operator actor, it proceeds.
use strict;
use warnings;
use Test::More;
use JSON::PP   qw(encode_json decode_json);
use IPC::Open2 qw(open2);
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root grant_caps);

my $root  = repo_root();
my $utool = "$root/tools/lazysite-users.pl";

sub uapi {
    my ( $d, $p ) = @_;
    my ( $o, $i );
    my $pid = open2( $o, $i, $^X, $utool, '--api', '--docroot', $d );
    print $i encode_json($p);
    close $i;
    my $out = do { local $/; <$o> };
    close $o;
    waitpid $pid, 0;
    return eval { decode_json($out) } // {};
}

my $d = tempdir( CLEANUP => 1 );
make_path("$d/lazysite/auth");
open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
print $cf "site_name: T\n";
close $cf;

uapi( $d, { action => 'add', username => 'op',    password => 'x' } );
uapi( $d, { action => 'add', username => 'boss',  password => 'x' } );
uapi( $d, { action => 'add', username => 'alice', password => 'x' } );
uapi( $d, { action => 'group-create', group => 'admins' } );
grant_caps( $d, 'op',   'manage_users' );        # a real operator
grant_caps( $d, 'boss', 'create_sub_users' );    # a delegated sub-manager, NOT manage_users

# --- a NON-OPERATOR actor is refused each escalation verb by the tool ----------
my %verb = (
    'group-add'          => { action => 'group-add', username => 'alice', group => 'admins' },
    'group-remove'       => { action => 'group-remove', username => 'alice', group => 'admins' },
    'group-settings-set' => { action => 'group-settings-set', group => 'admins', key => 'manage_users', value => 1 },
    'settings-set'       => { action => 'settings-set', username => 'alice', key => 'ui', value => 0 },
    'token'              => { action => 'token', username => 'alice' },
    'add'                => { action => 'add', username => 'intruder', password => 'x' },
    'remove'             => { action => 'remove', username => 'alice' },
    'group-create'       => { action => 'group-create', group => 'evil' },
    'group-delete'       => { action => 'group-delete', group => 'admins' },
);
for my $name ( sort keys %verb ) {
    my $r = uapi( $d, { %{ $verb{$name} }, actor => 'boss' } );
    ok( !$r->{ok}, "delegate actor is refused '$name' by the tool backstop" ) or diag encode_json($r);
    is( $r->{kind} // '', 'forbidden', "  ... refused as forbidden ($name)" );
}

# alice did not get into the admin group through any of the above.
my $ad = uapi( $d, { action => 'users-detail', username => 'alice' } );
my ($alice) = grep { ( $_->{user} // '' ) eq 'alice' } @{ $ad->{users} || [] };
ok( !( grep { $_ eq 'admins' } @{ $alice->{settings}{groups} || [] } ),
    'alice was not added to admins by any delegate-actor attempt' );

# --- an OPERATOR actor (manage_users) is allowed -------------------------------
{
    my $r = uapi( $d, { action => 'group-add', username => 'alice', group => 'admins', actor => 'op' } );
    ok( $r->{ok}, 'an operator actor (manage_users) may group-add' ) or diag encode_json($r);
}

# --- NO actor (direct CLI / operator context) is unconfined --------------------
{
    my $r = uapi( $d, { action => 'group-add', username => 'op', group => 'admins' } );
    ok( $r->{ok}, 'no actor => unconfined (CLI/operator context) still works' ) or diag encode_json($r);
}

done_testing();
