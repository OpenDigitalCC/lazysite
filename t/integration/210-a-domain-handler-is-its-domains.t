#!/usr/bin/perl
# SM1051 (inbox 2026-10-12, P-4): a handler may carry `domain:`, and then it is
# that domain's.
#
# Ruled 2026-10-12, "Domain-scoped handlers": a handler may carry `domain:`; a
# confined caller may create, edit and delete handlers bound to its own domains
# only (SM976 caller_may_reach_domain); forms on its pages may use those or
# instance handlers it may read; instance handlers stay operator-only
# (instance_wide unchanged for them).
#
# Callers: op, the cookie operator; tks, a token confined to mine.example.org;
# mcs, an MCP grant confined to the same domain.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use JSON::PP       qw(encode_json decode_json);
use MIME::Base64   qw(encode_base64);
use File::Path     qw(make_path);
use TestHelper     qw(repo_root run_child);
use ManagerSession qw(new_site);

my $root = repo_root();
plan skip_all => 'manager api missing' unless -f "$root/lazysite-manager-api.pl";
local $ENV{LAZYSITE_PROCESSOR} = "$root/lazysite-processor.pl";

my @ALL  = qw(ui api mcp manage_users manage_domains manage_content manage_forms);
my %CAPS = (
    op  => [qw(ui manage_users manage_domains manage_content manage_forms)],
    tks => [qw(api manage_content manage_forms)],
    mcs => [qw(mcp manage_content manage_forms)],
);

sub spit { my ( $p, $t ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh; return }

my $s = new_site( root => $root, conf => "control_api_enabled: true\nmcp_enabled: true\n" );
my $d = $s->docroot;
make_path( "$d/sites/mine", "$d/sites/other", "$d/lazysite/forms" );
for my $f (qw(mine other)) {
    spit( "$d/sites/$f/index.md", "# $f\n" );
    spit( "$d/sites/$f/contact.md", "---\ntitle: Contact\nform: ${f}_form\n---\n\n:::form\nname | Name\n:::\n" );
    spit( "$d/lazysite/forms/${f}_form.conf", "targets:\n" );
}
for my $u ( sort keys %CAPS ) {
    $s->add_user( $u, "pw-$u-0123456789" );
    $s->grant( $u, "g-$u", $CAPS{$u}, \@ALL );
}

sub uapi {
    my ($p) = @_;
    my $out = run_child( [ $^X, "$root/tools/lazysite-users.pl", '--api', '--docroot', $d ],
        stdin => encode_json($p), stderr => 'inherit' )->{out};
    return eval { decode_json($out) } // {};
}
my %tok = map { $_ => ( uapi( { action => 'token', username => $_ } )->{token} // '' ) } qw(tks mcs);

sub api {
    my ( $who, $action, $body, $query ) = @_;
    $query //= "action=$action";
    return $s->call( $who, $action, ( defined $body ? ( body => $body ) : () ), query => $query )
        if $who !~ /^tk/;
    my $json = defined $body ? encode_json($body) : undef;
    local %ENV = %ENV;
    delete @ENV{qw(HTTP_X_REMOTE_USER HTTP_X_REMOTE_GROUPS LAZYSITE_AUTH_TRUSTED HTTP_COOKIE HTTP_X_CSRF_TOKEN LAZYSITE_USERS_TOOL)};
    $ENV{DOCUMENT_ROOT}      = $d;
    $ENV{HTTP_AUTHORIZATION} = 'Basic ' . encode_base64( "$who:$tok{$who}", '' );
    $ENV{QUERY_STRING}       = $query;
    $ENV{REQUEST_METHOD}     = defined $json ? 'POST'       : 'GET';
    $ENV{CONTENT_LENGTH}     = defined $json ? length $json : 0;
    my $out = run_child( [ $^X, "$root/lazysite-manager-api.pl" ],
        stdin => ( $json // '' ) )->{out};
    my ($jb) = $out =~ /\r?\n\r?\n(.*)/s;
    return eval { decode_json( $jb // '' ) } // { _raw => $out };
}

sub mcp {
    my ( $who, $tool, $args ) = @_;
    my $body = encode_json( { jsonrpc => '2.0', id => 1, method => 'tools/call',
            params => { name => $tool, arguments => $args } } );
    local %ENV = %ENV;
    delete @ENV{qw(HTTP_X_REMOTE_USER LAZYSITE_AUTH_TRUSTED HTTP_COOKIE LAZYSITE_USERS_TOOL)};
    $ENV{DOCUMENT_ROOT}      = $d;
    $ENV{REQUEST_METHOD}     = 'POST';
    $ENV{CONTENT_LENGTH}     = length $body;
    $ENV{HTTP_AUTHORIZATION} = "Bearer $who:$tok{$who}";
    my $resp = run_child( [ $^X, "$root/lazysite-mcp.pl" ],
        stdin => $body, stderr => 'inherit' )->{out};
    my ($jb) = $resp =~ /\r?\n\r?\n(.*)/s;
    my $j = eval { decode_json( $jb // '' ) } || {};
    return { ok => 0, error => $j->{error}{message} } if $j->{error};
    return $j->{result}{structuredContent} || { ok => 0, error => 'no structured content' };
}

for my $set (
    [ 'domain-add', { host => 'mine.example.org',  content_root => 'sites/mine' } ],
    [ 'domain-add', { host => 'other.example.org', content_root => 'sites/other' } ],
    [ 'domain-set', { host => 'mine.example.org', key => 'allowed_groups', value => 'g-tks, g-mcs' } ],
    )
{
    my $r = api( 'op', @$set );
    ok( $r->{ok}, "set up: $set->[0] $set->[1]{host}" ) or diag( $r->{error} // '' );
}

sub refused {
    my ( $r, $label ) = @_;
    ok( !$r->{ok} && ( $r->{kind} // q() ) eq q(forbidden), "$label: refused as forbidden" )
        or diag( ( $r->{kind} // q() ) . q( - ) . ( $r->{error} // q() ) );
    return;
}
sub fh { my ( $id, %o ) = @_; return { id => $id, type => 'file', name => "H $id", %o } }
sub handler_ids { return join ',', sort map { $_->{id} } @{ $_[0]{handlers} || [] } }
sub stored {
    open my $fh, '<', "$d/lazysite/forms/handlers.conf" or return '';
    local $/;
    return scalar <$fh>;
}

subtest 'the operator: instance handlers and any domain\'s, unchanged' => sub {
    ok( api( 'op', 'handler-save', fh('inst') )->{ok}, 'an instance handler' );
    my $r = api( 'op', 'handler-save', fh( 'oth', domain => 'other.example.org' ) );
    ok( $r->{ok}, "another domain's handler" ) or diag( $r->{error} // '' );
    like( stored(), qr/- id: oth\n(?:    .*\n)*?    domain: other\.example\.org\n/, '...stored with its domain' );
    $r = api( 'op', 'handler-save', fh( 'nowhere', domain => 'nope.example.org' ) );
    is( $r->{kind}    // '', 'invalid', 'a domain the instance does not serve: invalid' );
    like( $r->{error} // '', qr/not a configured domain/, '...saying so' );
};

subtest 'a confined token: its own domain\'s handlers only' => sub {
    my $r = api( 'tks', 'handler-save', fh( 'mine-file', domain => 'mine.example.org' ) );
    ok( $r->{ok}, "a handler of its own domain: saved" ) or diag( $r->{error} // '' );
    $r = api( 'tks', 'handler-save', fh( 'mine-file', domain => 'mine.example.org', name => 'Renamed' ) );
    ok( $r->{ok}, '...and changed' ) or diag( $r->{error} // '' );

    $r = api( 'tks', 'handler-save', fh('loose') );
    ok( !$r->{ok}, 'an instance handler (no domain): refused' );
    is( $r->{kind} // '', 'forbidden', '...forbidden' );
    refused( api( q(tks), q(handler-save), fh( q(theirs), domain => q(other.example.org) ) ), q(a handler of another domain) );
    refused( api( q(tks), q(handler-save), fh( q(oth), domain => q(mine.example.org) ) ), q(taking another domain handler into its own) );
    $r = api( 'tks', 'handler-save', fh( 'inst', domain => 'mine.example.org' ) );
    ok( !$r->{ok}, 'taking an instance handler into its own domain: refused' );
    $r = api( 'tks', 'handler-save', fh('mine-file') );
    ok( !$r->{ok}, 'turning its own handler into an instance handler: refused' );
    unlike( stored(), qr/- id: (?:loose|theirs)\n/, 'nothing refused was written' );
    like( stored(), qr/- id: oth\n(?:    .*\n)*?    domain: other\.example\.org\n/, "...and the other domain's handler is unchanged" );

    is( handler_ids( api( 'tks', 'handler-list' ) ), 'inst,mine-file', "handler-list: the instance's and its own" );

    $r = api( 'tks', 'form-targets-save', { form => 'mine_form', handlers => [ 'mine-file', 'inst' ] } );
    ok( $r->{ok}, 'its form binds its own and an instance handler' ) or diag( $r->{error} // '' );
    $r = api( 'tks', 'form-targets-save', { form => 'mine_form', handlers => ['oth'] } );
    ok( !$r->{ok}, "...and not another domain's" );
    like( $r->{error} // '', qr/belongs to the domain 'other\.example\.org'/, '...saying whose it is' );

    refused( api( q(tks), q(handler-delete), { id => q(oth) } ), q(deleting another domain handler) );
    ok( !api( 'tks', 'handler-delete', { id => 'inst' } )->{ok}, 'deleting an instance handler: refused' );
    ok( api( 'tks', 'form-targets-save', { form => 'mine_form', handlers => [] } )->{ok}, 'unbinding its form' );
    $r = api( 'tks', 'handler-delete', { id => 'mine-file' } );
    ok( $r->{ok}, '...then deleting its own handler' ) or diag( $r->{error} // '' );
};

subtest 'the MCP twins ask the same rule' => sub {
    my $r = mcp( 'mcs', 'save_handler', fh( 'm-file', domain => 'mine.example.org' ) );
    ok( $r->{ok}, 'save_handler: its own domain' ) or diag( $r->{error} // '' );
    ok( !mcp( 'mcs', 'save_handler', fh('m-loose') )->{ok}, 'save_handler: an instance handler, refused' );
    ok( !mcp( 'mcs', 'save_handler', fh( 'oth', domain => 'mine.example.org' ) )->{ok},
        "save_handler: another domain's handler, refused" );
    refused( mcp( q(mcs), q(delete_handler), { id => q(oth) } ), q(delete_handler of another domain) );
    is( join( ',', sort map { $_->{id} } @{ mcp( 'mcs', 'list_handlers', {} )->{handlers} || [] } ),
        'inst,m-file', "list_handlers: the instance's and its own" );
    ok( !mcp( 'mcs', 'bind_form', { form => 'mine_form', handler => 'oth' } )->{ok},
        "bind_form: another domain's handler, refused" );
    ok( mcp( 'mcs', 'bind_form', { form => 'mine_form', handler => 'm-file' } )->{ok}, 'bind_form: its own' );
};

done_testing;
