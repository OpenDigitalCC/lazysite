#!/usr/bin/perl
# SM944 S32 (4), ruled 2026-10-10 ("Yes, all four"): the account store is read
# for an account. Inside a request the dispatcher has refused an empty
# $auth_user before users, principals or display-names runs, so their answers
# there are unchanged (t/unit/manager/16, 23 and t/unit/users/28 drive them
# through requests). Reached outside one - the request context as its reset
# leaves it, nobody - action_users and action_principals listed every account
# and action_display_names resolved the names asked
# (tmp/sm944-s31-s32-refusal-probe.out). Now each refuses an empty account
# before it asks the users tool.
#
# Loaded the way the unit tests load the script (LAZYSITE_API_LOAD_ONLY:
# compiled, no request run), on a site with two accounts.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);
use lib repo_root() . '/lib';
use ManagerSession qw(new_site);

my $s   = new_site( root => repo_root() );
my @ALL = qw(ui manage_users manage_content);
$s->add_user('boss');
$s->grant( 'boss', 'bosses', \@ALL, \@ALL );
$s->add_user('alice');
local $ENV{LAZYSITE_USERS_TOOL}          = repo_root() . '/tools/lazysite-users.pl';
local $ENV{LAZYSITE_LOG_LEVEL}           = 'ERROR';
local $ENV{LAZYSITE_FORWARD_DIAGNOSTICS} = 'off';
local $ENV{REQUEST_METHOD}               = 'GET';

BEGIN { $ENV{LAZYSITE_API_LOAD_ONLY} = 1 }
my $api = repo_root() . '/lazysite-manager-api.pl';
{
    local $ENV{DOCUMENT_ROOT} = $s->docroot;
    package main;
    do $api or die "load failed: $@";
}
Lazysite::Manager::Common::reset_request_context();

sub refused {
    my ( $r, $what, @keys ) = @_;
    is( $r->{kind} // '', 'forbidden', $what ) or diag explain $r;
    ok( !$r->{ok}, '...not ok' );
    like( $r->{error} // '', qr/no account is asking/, '...saying why' );
    ok( !( grep { exists $r->{$_} } @keys ), "...with no @keys" );
    return;
}

sub as_boss {
    no warnings 'once';
    $Lazysite::Manager::Common::auth_user  = 'boss';
    $Lazysite::Manager::Common::token_auth = 0;
    return;
}

subtest 'users, outside a request, lists no account' => sub {
    refused( main::action_users( '', { sub => 'list' } ), 'refused', 'users' );
};

subtest 'for an account users lists them; after a reset, refused again' => sub {
    as_boss();
    my $r = main::action_users( '', { sub => 'list' } );
    ok( $r->{ok}, 'listed' ) or diag explain $r;
    is_deeply( [ sort map { ref $_ ? $_->{user} : $_ } @{ $r->{users} || [] } ], [qw(alice boss)], '...both accounts' );
    Lazysite::Manager::Common::reset_request_context();
    refused( main::action_users( '', { sub => 'list' } ), 'reset: refused again', 'users' );
};

done_testing();
