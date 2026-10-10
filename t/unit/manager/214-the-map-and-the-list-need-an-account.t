#!/usr/bin/perl
# SM944 S25 (a)-(b), ruled 2026-10-10 ("Yes, (a)-(d)"): describe-capabilities
# and actions-list answer for an account. Inside a request the dispatcher has
# refused an empty $auth_user before any action runs, so their answer there is
# unchanged (t/unit/manager/10, 112). Reached outside one - the request context
# as its reset leaves it, nobody - action_describe_capabilities answered ok:1
# for account '' with the capability map, the site's documentation index and
# every action's effects, and action_actions_list answered ok:1 with the
# actions a grant of nothing may call (tmp/sm944-s25-refusal-probe.out). Now
# both refuse.
#
# The script is loaded the way the unit tests load it (LAZYSITE_API_LOAD_ONLY:
# compiled, no request run), and the context is reset as any process that
# never sets one leaves it.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper     qw(repo_root);
use ManagerSession qw(new_site);
use lib repo_root() . '/lib';

my $s = new_site( root => repo_root() );
my $d = $s->docroot;
$s->add_user('boss');
$s->grant( 'boss', 'bosses', [qw(ui api manage_content)], [qw(ui api manage_content)] );
mkdir "$d/docs";
open my $p, '>', "$d/docs/guide.md" or die $!;
print {$p} "---\ntitle: Guide\n---\nG\n";
close $p;
local $ENV{LAZYSITE_USERS_TOOL}          = repo_root() . '/tools/lazysite-users.pl';
local $ENV{LAZYSITE_LOG_LEVEL}           = 'ERROR';
local $ENV{LAZYSITE_FORWARD_DIAGNOSTICS} = 'off';

BEGIN { $ENV{LAZYSITE_API_LOAD_ONLY} = 1 }
my $api = repo_root() . '/lazysite-manager-api.pl';
{
    local $ENV{DOCUMENT_ROOT} = $d;
    package main;
    do $api or die "load failed: $@";
}
Lazysite::Manager::Common::reset_request_context();
my $nobody = do { no warnings 'once'; $Lazysite::Manager::Common::auth_user };

subtest 'describe-capabilities, outside a request, describes nothing' => sub {
    is( $nobody, '', 'nobody is asking' );
    my $r = main::action_describe_capabilities($nobody);
    is( $r->{kind} // '', 'forbidden', 'refused' ) or diag explain [ sort keys %$r ];
    ok( !$r->{ok}, '...not ok' );
    like( $r->{error} // '', qr/no account is asking/, '...saying why' );
    ok( !exists $r->{docs} && !exists $r->{actions} && !exists $r->{capabilities},
        '...with no map, docs index or actions' );
    $r = main::action_describe_capabilities(undef);
    is( $r->{kind} // '', 'forbidden', 'an undefined account is refused too' );

    # The same call for an account answers - so it is the empty account that is
    # refused, not the fixture.
    $r = main::action_describe_capabilities('boss');
    ok( $r->{ok}, 'for an account it answers' ) or diag explain $r;
    is( $r->{holds}{account} // '', 'boss', '...describing that account' );
    ok( ref $r->{actions} eq 'HASH' && %{ $r->{actions} }, '...with the actions block' );
};

done_testing();
