#!/usr/bin/perl
# SM944 S26 (c), ruled 2026-10-10 ("Yes, (a)-(d)"): analyse_visitors reads the
# stats for an account. Inside a request the dispatcher has refused an empty
# $auth_user and required `analytics` before it runs, so its answer there is
# unchanged (t/unit/manager/10). Reached outside one - the request context as
# its reset leaves it, nobody - action_analyse_visitors ran the stats plugin and
# returned its export (tmp/sm944-s26-refusal-probe.out). Now it refuses before
# it runs the tool.
#
# The script is loaded the way the unit tests load it (LAZYSITE_API_LOAD_ONLY:
# compiled, no request run), and the context is reset as any process that
# never sets one leaves it. The stats tool is a stand-in that leaves a mark when
# it runs.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root site_tempdir);
use lib repo_root() . '/lib';

my $d = site_tempdir();
mkdir "$d/lazysite";
sub spit { my ( $p, $t ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh; return }
spit( "$d/lazysite/lazysite.conf",       "site_name: T\ncontrol_api_enabled: true\n" );
spit( "$d/lazysite/.install-state.json", '{"version":"9.8.7"}' );
# It writes the arguments it was given, so the docroot it is handed is seen.
spit( "$d/stats-stub.pl", "open my \$m, '>', '$d/ran' or die; print {\$m} join(' ', \@ARGV); close \$m;\n"
        . "print '{\"ok\":1,\"top_pages\":[{\"path\":\"/secret-campaign\",\"hits\":42}]}';\n" );
local $ENV{LAZYSITE_STATS_TOOL}          = "$d/stats-stub.pl";
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

subtest 'analyse_visitors, outside a request, runs nothing' => sub {
    is( do { no warnings 'once'; $Lazysite::Manager::Common::auth_user }, '', 'nobody is asking' );
    my $r = main::action_analyse_visitors( window => 7 );
    is( $r->{kind} // '', 'forbidden', 'refused' ) or diag explain $r;
    ok( !$r->{ok}, '...not ok' );
    like( $r->{error} // '', qr/no account is asking/, '...saying why' );
    ok( !exists $r->{top_pages}, '...handing over no stats' );
    ok( !-e "$d/ran",            '...and the stats tool did not run' );

    # The same call for an account runs it - so it is the empty account that is
    # refused, not the fixture.
    no warnings 'once';
    $Lazysite::Manager::Common::auth_user = 'boss';
    $r                                    = main::action_analyse_visitors( window => 7 );
    ok( $r->{ok}, 'for an account it answers' ) or diag explain $r;
    is( $r->{top_pages}[0]{path} // '', '/secret-campaign', '...with the export' );
    ok( -e "$d/ran", '...from the stats tool' );
    like( do { open my $r, '<', "$d/ran" or die $!; local $/; <$r> }, qr/--docroot \Q$d\E /,
        '...handed the docroot the dispatcher set (SM944 S26: Services\' own)' );
    unlink "$d/ran";
    Lazysite::Manager::Common::reset_request_context();
    is( main::action_analyse_visitors( window => 7 )->{kind} // '', 'forbidden', 'reset: refused again' );
    ok( !-e "$d/ran", '...running nothing' );
};

# (d) unchanged, read through the dirs the dispatcher sets on Services.
subtest 'the site facts answer from the dispatcher\'s dirs' => sub {
    is( main::action_version()->{version} // '', '9.8.7', 'version: the install state under the lazysite dir' );
    my $on = Lazysite::Manager::Services::_service_state();
    ok( $on->{api} && !$on->{mcp}, 'the transports\' state: read from the docroot\'s conf' ) or diag explain $on;
    ok( main::action_channel_services()->{services}{api}, 'channel-services: the same switch' );
};

done_testing();
