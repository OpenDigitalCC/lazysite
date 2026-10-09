#!/usr/bin/perl
# SM944 S21: the manager request context is fail-closed until a request sets it.
#
# The facts a manager-API request establishes about itself live in
# Lazysite::Manager::Common, so an area module reads them wherever it is loaded:
# in the manager API, which sets them, and in the daemon, MCP, WebDAV or a test,
# which never do. Before the context was shared it was the script's own `my`
# variables and nothing else could reach them; once shared, the value a reader
# sees before anything set it is a decision. An empty scope set means
# UNCONFINED to every reader, so "empty" would have handed a handler loaded
# outside a request the sysop's reach. This file is a plain perl process that
# never runs the script: what it sees is what any other loader sees.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);
use lib repo_root() . '/lib';
use Lazysite::Manager::Common qw(outside_all_scopes reset_request_context NO_REQUEST_CONTEXT
    $auth_user $token_auth %token_caps @REQUEST_SCOPES $REQUEST_CONFINED $IS_OPERATOR $action $path $body);

my @PATHS = ( '', '/', 'index.md', 'sites/clienta/index.md', 'lazysite/auth/users', 'no request context',
    'sites', '/sites/clienta/' );

sub fail_closed {
    my ($when) = @_;
    is( $auth_user, '', "$when: nobody is asking" );
    ok( $token_auth, "$when: a token client, so never the cookie session that is the operator" );
    is_deeply( [ grep { $_ ne 'dav_scopes' } keys %token_caps ], [], "$when: the token holds no capability" );
    ok( scalar @REQUEST_SCOPES, "$when: the scope set is not empty (empty means unconfined)" );
    is_deeply( [ grep { !outside_all_scopes( \@REQUEST_SCOPES, $_ ) } @PATHS ], [],
        "$when: every path is outside the request's scopes" );
    is_deeply( [ grep { !outside_all_scopes( $token_caps{dav_scopes}, $_ ) } @PATHS ], [],
        "$when: and outside the token's own" );
    ok( $REQUEST_CONFINED, "$when: confined" );
    ok( defined $IS_OPERATOR && !$IS_OPERATOR, "$when: not the operator, and the memo is filled so nothing asks again" );
    is( $action, '',    "$when: no action" );
    is( $path,   undef, "$when: no path" );
    is( $body,   '',    "$when: no body" );
}

fail_closed('loaded, never set');
is( index( NO_REQUEST_CONTEXT(), "\0" ) >= 0, 1, 'the no-context scope holds a NUL, which no path or root can' );

# What the manager API sets for an operator request; then the reset it runs
# before its auth check, as a process that served one request would.
$auth_user        = 'boss';
$token_auth       = 0;
%token_caps       = ( manage_users => 1, dav_scopes => [] );
@REQUEST_SCOPES   = ();
$REQUEST_CONFINED = 0;
$IS_OPERATOR      = 1;
$action           = 'acl-set';
$path             = 'secret/page.md';
$body             = '{"read":["@everyone"]}';
reset_request_context();
fail_closed('after a request, reset');

# The modules long-lived processes load leave it as it is.
require Lazysite::Handlers;
require Lazysite::Manager::Files;
require Lazysite::Manager::Domains;
fail_closed('after loading the daemon\'s handlers and two manager modules');

# SM944 S22: a real handler. The remap actions read the context from Common;
# loaded here, with a site that has a domain and a rule for it (made through
# the manager API, as an operator would), they refuse every host and list no
# rule - and the same calls with an operator's context see both, so it is the
# context that refuses, not the fixture.
subtest 'the remap handlers, loaded outside a request, reach no domain' => sub {
    require ManagerSession;
    require Lazysite::Manager::Remap;
    my $s   = ManagerSession::new_site( root => repo_root() );
    my @ALL = qw(ui manage_domains manage_users manage_config);
    $s->add_user('boss');
    $s->grant( 'boss', 'bosses', \@ALL, \@ALL );
    open my $cf, '>>', $s->docroot . '/lazysite/lazysite.conf' or die $!;
    print {$cf} "extensions:\n  - plugins/remap.pl\n";
    close $cf;
    my $d = $s->call( 'boss', 'domain-add',
        body => { host => 'mine.example.org', content_root => 'sites/mine',
            site_url => 'https://mine.example.org', site_name => 'mine' } );
    ok( $d->{ok}, 'set up a domain' ) or diag( $d->{error} // '' );
    my $w = $s->call( 'boss', 'remap-save',
        body => { host => 'mine.example.org', rules => [ { prefix => '/web', destination => 'https://b.example.com' } ] } );
    ok( $w->{ok}, '...and a rule for it' ) or diag( $w->{error} // '' );

    no warnings 'once';
    $Lazysite::Manager::Remap::DOCROOT = $s->docroot; # what an entry point that loads it would set:
    $Lazysite::Manager::Plugins::DOCROOT = $s->docroot; # where the site is - never who is asking
    $Lazysite::Manager::Domains::DOCROOT = $s->docroot;
    $Lazysite::Manager::Common::DOCROOT  = $s->docroot;
    my $rule = [ { prefix => '/x', destination => 'https://elsewhere.example.com' } ];

    my $l = Lazysite::Manager::Remap::_remap_list();
    is_deeply( $l->{rules}, [], 'remap-list lists no rule' ) or diag explain $l;
    my $r = Lazysite::Manager::Remap::_remap_save( { host => 'mine.example.org', rules => $rule } );
    is( $r->{kind} // '', 'forbidden', 'remap-save refuses the registered domain' ) or diag explain $r;
    $r = Lazysite::Manager::Remap::_remap_save( { host => 'unregistered.example.net', rules => $rule } );
    is( $r->{kind} // '', 'forbidden', '...and an unregistered host' ) or diag explain $r;

    # The operator's context, as the script sets it.
    $token_auth     = 0;
    %token_caps     = ();
    @REQUEST_SCOPES = ();
    $l              = Lazysite::Manager::Remap::_remap_list();
    is( scalar @{ $l->{rules} || [] }, 1, 'with an operator\'s context the same call lists the rule' );
    reset_request_context();
    is_deeply( Lazysite::Manager::Remap::_remap_list()->{rules}, [], '...and reset, none again' );
};

done_testing();
