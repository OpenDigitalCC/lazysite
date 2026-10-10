#!/usr/bin/perl
# SM944 S30, the established fail-closed pattern (ruled 2026-10-09/10 for S23-
# S28): config-set writes lazysite.conf for an account. Inside a request the
# dispatcher has refused an empty $auth_user and required `manage_config` before
# it runs, so its answer there is unchanged (tests manager/17, 110, 134 and
# integration/114 drive it through requests). Reached outside one - the request
# context as its reset leaves it, nobody - action_config_set wrote site_name
# into the conf (tmp/sm944-s29-s30-refusal-probe.out). Now it refuses before it
# reads the key.
#
# Loaded the way the unit tests load the script (LAZYSITE_API_LOAD_ONLY:
# compiled, no request run).
use strict;
use warnings;
use Test::More;
use FindBin;
use File::Path qw(make_path);
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root site_tempdir);
use lib repo_root() . '/lib';

my $d = site_tempdir();
make_path("$d/lazysite");
my $CONF = "site_name: T\nsite_url: https://primary.example\n";
sub conf { open my $fh, '<', "$d/lazysite/lazysite.conf" or return ''; local $/; return scalar <$fh> }
{
    open my $fh, '>', "$d/lazysite/lazysite.conf" or die $!;
    print {$fh} $CONF;
    close $fh;
}
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

subtest 'config-set, outside a request, writes nothing' => sub {
    is( do { no warnings 'once'; $Lazysite::Manager::Common::auth_user }, '', 'nobody is asking' );
    my $r = main::action_config_set( 'site_name', 'Nobody' );
    is( $r->{kind} // '', 'forbidden', 'refused' ) or diag explain $r;
    ok( !$r->{ok}, '...not ok' );
    like( $r->{error} // '', qr/no account is asking/, '...saying why' );
    is( conf(), $CONF, '...and the conf is unchanged' );

    # The same call for an account writes it - so it is the empty account that
    # is refused, not the fixture.
    no warnings 'once';
    $Lazysite::Manager::Common::auth_user = 'boss';
    $r = main::action_config_set( 'site_name', 'Boss' );
    ok( $r->{ok}, 'for an account the key is set' ) or diag explain $r;
    like( conf(), qr/^site_name: Boss$/m, '...in the conf' );
    Lazysite::Manager::Common::reset_request_context();
    is( main::action_config_set( 'site_name', 'Nobody' )->{kind} // '', 'forbidden', 'reset: refused again' );
    like( conf(), qr/^site_name: Boss$/m, '...writing nothing' );
};

done_testing();
