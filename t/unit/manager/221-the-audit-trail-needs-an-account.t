#!/usr/bin/perl
# SM944 S31, the established fail-closed pattern (ruled 2026-10-10): the audit
# trail is read for an account. Inside a request the dispatcher has refused an
# empty $auth_user (and asked for `audit`, or narrowed a sub-user manager to
# its team) before action_audit runs, so its answer there is unchanged
# (t/unit/manager/23, 35 and 10 read the trail through requests). Reached
# outside one - the request context as its reset leaves it, nobody - it
# answered with the whole trail, every actor and target
# (tmp/sm944-s31-s32-refusal-probe.out). Now it refuses before it reads the
# trail. action_recent_changes is the same: who last changed each target, for
# account '' (test 23 reads it through requests); refused the same way.
#
# Loaded the way the unit tests load the script (LAZYSITE_API_LOAD_ONLY:
# compiled, no request run).
use strict;
use warnings;
use Test::More;
use FindBin;
use File::Path qw(make_path);
use POSIX      qw(strftime);
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root site_tempdir);
use lib repo_root() . '/lib';

my $d = site_tempdir();
make_path( "$d/lazysite/logs", "$d/lazysite/cache" );
sub spit { open my $fh, '>', $_[0] or die "$_[0]: $!"; print {$fh} $_[1]; close $fh; return }
spit( "$d/lazysite/lazysite.conf", "site_name: T\n" );
my $now = strftime( '%Y-%m-%dT%H:%M:%SZ', gmtime );
spit( "$d/lazysite/logs/audit.log",
    "$now | boss | save | secret/plan.md | 10.0.0.1 | ok | ui | \n"
        . "$now | alice | delete | hr/salaries.md | 10.0.0.2 | ok | api | \n" );
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

subtest 'audit, outside a request, hands over no trail' => sub {
    is( do { no warnings 'once'; $Lazysite::Manager::Common::auth_user }, '', 'nobody is asking' );
    my $r = main::action_audit();
    is( $r->{kind} // '', 'forbidden', 'refused' ) or diag explain $r;
    ok( !$r->{ok}, '...not ok' );
    like( $r->{error} // '', qr/no account is asking/, '...saying why' );
    ok( !exists $r->{entries} && !exists $r->{users} && !exists $r->{targets},
        '...with no entries, actors or targets' );
};

subtest 'for an account the trail is read; after a reset, refused again' => sub {
    no warnings 'once';
    $Lazysite::Manager::Common::auth_user = 'boss';
    my $r = main::action_audit();
    ok( $r->{ok}, 'read' ) or diag explain $r;
    is( scalar @{ $r->{entries} || [] }, 2, '...both entries' );
    is_deeply( $r->{targets}, [ 'hr/salaries.md', 'secret/plan.md' ], '...and their targets' );

    Lazysite::Manager::Common::reset_request_context();
    $r = main::action_audit();
    is( $r->{kind} // '', 'forbidden', 'reset: refused again' );
    ok( !exists $r->{entries}, '...with no entries' );
};

subtest 'recent-changes, outside a request, names nobody who changed anything' => sub {
    Lazysite::Manager::Common::reset_request_context();
    my $r = main::action_recent_changes();
    is( $r->{kind} // '', 'forbidden', 'refused' ) or diag explain $r;
    ok( !$r->{ok}, '...not ok' );
    like( $r->{error} // '', qr/no account is asking/, '...saying why' );
    ok( !exists $r->{changes}, '...with no changes' );
};

subtest 'for an account recent changes are read; after a reset, refused again' => sub {
    no warnings 'once';
    $Lazysite::Manager::Common::auth_user = 'boss';
    my $r = main::action_recent_changes();
    ok( $r->{ok}, 'read' ) or diag explain $r;
    is_deeply( [ sort keys %{ $r->{changes} || {} } ], [ 'hr/salaries.md', 'secret/plan.md' ],
        '...who last changed each target' );

    Lazysite::Manager::Common::reset_request_context();
    $r = main::action_recent_changes();
    is( $r->{kind} // '', 'forbidden', 'reset: refused again' );
    ok( !exists $r->{changes}, '...with no changes' );
};

done_testing();
