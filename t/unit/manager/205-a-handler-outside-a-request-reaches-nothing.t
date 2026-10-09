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
is( index( NO_REQUEST_CONTEXT, "\0" ) >= 0, 1, 'the no-context scope holds a NUL, which no path or root can' );

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

done_testing();
