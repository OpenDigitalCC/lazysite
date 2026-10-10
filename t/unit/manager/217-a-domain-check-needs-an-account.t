#!/usr/bin/perl
# SM944 S27, the established fail-closed pattern (ruled 2026-10-10, "Read
# Common's value"): domain-check probes for an account. Inside a request the
# dispatcher has refused an empty $auth_user and asked the domain rule before it
# runs, so its answer there is unchanged (test manager/33 drives it through
# requests). Reached outside one - the request context as its reset leaves it,
# nobody - action_domain_check ran its outbound DNS/TLS probe of a configured
# host (tmp/sm944-s27-s28-refusal-probe.out). Now it refuses before the probe.
#
# The account it reads is Manager::Common's, which the reset empties. The row's
# target module, Manager::Domains, keeps its own copy of the acting user for log
# attribution, which the dispatcher sets per request and nothing resets: the
# second subtest is the case that copy would miss - a request has run, the
# context is reset, the copy still names its account - and the check must
# refuse.
#
# Loaded the way the unit tests load the script (LAZYSITE_API_LOAD_ONLY:
# compiled, no request run). No network: the probe is a stand-in that counts
# its calls, and the install's own public addresses are none.
use strict;
use warnings;
use Test::More;
use FindBin;
use File::Path qw(make_path);
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root site_tempdir);
use lib repo_root() . '/lib';

my $d = site_tempdir();
make_path( "$d/lazysite", "$d/sites/a" );
{
    open my $fh, '>', "$d/lazysite/lazysite.conf" or die $!;
    print {$fh} "site_name: T\nsite_url: https://primary.example\n"
        . "alias_hosts: a.example\nalias.a.example.content_root: sites/a\n";
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

# The outbound probe, wherever the check is compiled: the script imports
# Domains' domain_check, and a check moved into Domains calls its own.
my $probed = 0;
{
    no warnings qw(once redefine);
    my $stub = sub { $probed++; return { ok => 1, host => $_[0], live => 1 } };
    *main::domain_check                              = $stub;
    *Lazysite::Manager::Domains::domain_check        = $stub;
    *Lazysite::Manager::Domains::instance_public_ips = sub { return () };
}
Lazysite::Manager::Common::reset_request_context();

sub common_user  { no warnings 'once'; return $Lazysite::Manager::Common::auth_user }
sub domains_user { no warnings 'once'; return $Lazysite::Manager::Domains::auth_user }

subtest 'domain-check, outside a request, probes nothing' => sub {
    is( common_user(), '', 'nobody is asking' );
    my $r = main::action_domain_check('a.example');
    is( $r->{kind} // '', 'forbidden', 'refused' ) or diag explain $r;
    ok( !$r->{ok}, '...not ok' );
    like( $r->{error} // '', qr/no account is asking/, '...saying why' );
    is( $probed, 0, '...and the outbound probe did not run' );

    # The same call for an account runs it - so it is the empty account that is
    # refused, not the fixture.
    no warnings 'once';
    $Lazysite::Manager::Common::auth_user = 'boss';
    $r                                    = main::action_domain_check('a.example');
    ok( $r->{ok} && ( $r->{host} // '' ) eq 'a.example', 'for an account the check runs' ) or diag explain $r;
    is( $probed, 1, '...through the probe' );
    Lazysite::Manager::Common::reset_request_context();
    is( main::action_domain_check('a.example')->{kind} // '', 'forbidden', 'reset: refused again' );
    is( $probed,                                              1, '...probing nothing' );
};

subtest 'after a request, reset: a module\'s own copy of the account does not count' => sub {
    # What the dispatcher sets for a manager's request: Common's fact, and
    # Domains' log-attribution copy of it (SM154).
    no warnings 'once';
    $Lazysite::Manager::Common::auth_user  = 'boss';
    $Lazysite::Manager::Domains::auth_user = 'boss';
    Lazysite::Manager::Common::reset_request_context();
    is( common_user(), '',      'the reset empties Common\'s account' );
    is( domains_user(), 'boss', '...and leaves Domains\' copy naming the last request\'s' );
    my $r = main::action_domain_check('a.example');
    is( $r->{kind} // '', 'forbidden', 'the check refuses all the same' ) or diag explain $r;
    is( $probed,          1,           '...probing nothing' );
};

done_testing();
