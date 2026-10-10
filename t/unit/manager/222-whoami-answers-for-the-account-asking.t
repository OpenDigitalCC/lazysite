#!/usr/bin/perl
# SM944 S32 (3), ruled 2026-10-10 ("Yes, all four"): whoami answers for the
# account that is asking, and for no other. Inside a request the dispatcher
# passes $auth_user, which it has refused empty, so the answer there is
# unchanged - the first subtest asks it through a request. Reached outside one -
# the request context as its reset leaves it, nobody - action_whoami answered
# for account '' and for any account it was handed, with nobody signed in as it
# (tmp/sm944-s31-s32-refusal-probe.out). Now it refuses unless its account is
# the request's own.
#
# The script is also loaded the way the unit tests load it
# (LAZYSITE_API_LOAD_ONLY: compiled, no request run).
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);
use lib repo_root() . '/lib';
use ManagerSession qw(new_site);

my $s   = new_site( root => repo_root() );
my @ALL = qw(ui manage_users manage_config);
$s->add_user('boss');
$s->grant( 'boss', 'bosses', \@ALL, \@ALL );
$s->add_user('alice');
local $ENV{LAZYSITE_USERS_TOOL}          = repo_root() . '/tools/lazysite-users.pl';
local $ENV{LAZYSITE_LOG_LEVEL}           = 'ERROR';
local $ENV{LAZYSITE_FORWARD_DIAGNOSTICS} = 'off';

subtest 'inside a request whoami answers for the account asking' => sub {
    delete local $ENV{LAZYSITE_API_LOAD_ONLY};  # set below, at compile time, for the load
    my $r = $s->call( 'boss', 'whoami', query => 'action=whoami&plugins=0' );
    ok( $r->{ok}, 'answered' ) or diag explain $r;
    is( $r->{user}, 'boss', '...for boss' );
    ok( exists $r->{manager_groups}, '...with what boss may see' );
};

BEGIN { $ENV{LAZYSITE_API_LOAD_ONLY} = 1 }
my $api = repo_root() . '/lazysite-manager-api.pl';
{
    local $ENV{DOCUMENT_ROOT} = $s->docroot;
    package main;
    do $api or die "load failed: $@";
}
Lazysite::Manager::Common::reset_request_context();

sub refused {
    my ( $r, $what ) = @_;
    is( $r->{kind} // '', 'forbidden', $what ) or diag explain $r;
    ok( !$r->{ok} && !exists $r->{user} && !exists $r->{capabilities}, '...answering nothing about it' );
    return;
}

subtest 'outside a request whoami answers for nobody, named or not' => sub {
    is( do { no warnings 'once'; $Lazysite::Manager::Common::auth_user }, '', 'nobody is asking' );
    refused( main::action_whoami( '',    0 ), 'account \'\' is refused' );
    refused( main::action_whoami( undef, 0 ), 'an undefined account is refused' );
    refused( main::action_whoami( 'boss', 0 ), 'a named account nobody signed in as is refused' );
};

subtest 'for boss, whoami answers for boss and for no one else; after a reset, for nobody' => sub {
    no warnings 'once';
    $Lazysite::Manager::Common::auth_user  = 'boss';
    $Lazysite::Manager::Common::token_auth = 0;
    my $r = main::action_whoami( 'boss', 0 );
    ok( $r->{ok}, 'boss is answered' ) or diag explain $r;
    is( $r->{user}, 'boss', '...as boss' );
    refused( main::action_whoami( 'alice', 0 ), 'another account is refused' );

    Lazysite::Manager::Common::reset_request_context();
    refused( main::action_whoami( 'boss', 0 ), 'reset: boss is refused again' );
};

done_testing();
