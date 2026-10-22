#!/usr/bin/perl
# SM1057: the domain a request arrives on changes neither which rule governs a
# path nor who counts as the operator - on the manager, MCP and WebDAV.
#
# The report from sites.lazysite.io offered two readings of a member's 200s on
# a domain, and this file is the measure that tells them apart from the one
# that was true (t/integration/220):
#
#   1. "a domain reads its own group settings, finds no manager grant, and so
#      counts as unsecured - every signed-in account an operator". Every door
#      reads the instance's auth store from the instance's engine tree, which
#      the Host does not choose. Measured below by an account that holds `ui`
#      and nothing else: refused manage_config on the domain's host as on the
#      primary's. The control is the same account on a site where no group
#      grants manager access, where it IS the operator - so the probe can see
#      operator status, and a pass is not a probe that sees nothing.
#   2. "a save on the host looks up `post/...` while the rule is keyed
#      `sites/<domain>/...`". Every door's paths, and so its rule keys, are
#      docroot-relative whichever host carries the request - the key acl-set
#      writes. A writer the rule does not name is refused the content-root
#      path on the domain's host, for read and write, on all three doors.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use File::Path     qw(make_path);
use JSON::PP       qw(encode_json decode_json);
use MIME::Base64   qw(encode_base64);
use ManagerSession qw(new_site);
use TestHelper     qw(repo_root run_dav run_child);

my $root = repo_root();
plan skip_all => 'manager api missing' unless -f "$root/lazysite-manager-api.pl";

my $HOST = 'tprf.example.org';
my @ALL  = qw(ui api mcp webdav manage_users manage_content manage_config);

sub spit { my ( $p, $t ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh; return }
sub slurp { my ($p) = @_; open my $fh, '<', $p or return undef; local $/; my $t = <$fh>; close $fh; return $t }

sub site {
    my (%o) = @_;
    my $s = new_site( root => $root,
        conf => "control_api_enabled: true\nmcp_enabled: true\nwebdav_enabled: true\nmanager: enabled\n"
            . "alias_hosts: $HOST\nalias.$HOST.content_root: sites/tprf\n" );
    my $d = $s->docroot;
    make_path( "$d/sites/tprf/post", "$d/sites/tprf/private" );
    spit( "$d/index.md",                "# primary\n" );
    spit( "$d/sites/tprf/index.md",     "# tprf\n" );
    spit( "$d/sites/tprf/post/p.md",    "# a post\n" );
    spit( "$d/sites/tprf/private/x.md", "# private\n" );
    for my $u ( @{ $o{users} } ) {
        my ( $name, $group, $caps ) = @$u;
        $s->add_user( $name, "pw-$name-0123456789" );
        $s->grant( $name, $group, $caps, \@ALL ) if defined $group;
    }
    return ( $s, $d );
}

sub on_host {
    my ( $host, $code ) = @_;
    local $ENV{HTTP_HOST} = $host if defined $host;
    delete local $ENV{HTTP_HOST} unless defined $host;
    return $code->();
}

# --- reading 1: the operator is the instance's, whatever the host ------------
{
    my ( $s, $d ) = site( users => [ [ 'sysop', 'sysops', [qw(ui manage_users manage_content manage_config)] ],
            [ 'viewer', 'viewers', ['ui'] ] ] );
    for my $host ( $HOST, undef ) {
        my $on = defined $host ? "on $host" : 'on the primary';
        my $r  = on_host( $host, sub { $s->call( 'viewer', 'config-read' ) } );
        ok( ManagerSession->refused_for_capability($r), "a ui-only account is not the operator $on" )
            or diag explain $r;
    }

    # The control: no group grants manager access, so every signed-in account is
    # the operator (the dev/first-run mode). The same request is served.
    # The users tool seeds groups that grant `ui`, so the store is written here,
    # after it, holding the one group: an existing store is not reseeded.
    my ( $u, $ud ) = site( users => [ [ 'viewer', 'viewers', ['manage_content'] ] ] );
    spit( "$ud/lazysite/auth/groups-settings.json", encode_json( { viewers => { manage_content => JSON::PP::true } } ) );
    for my $host ( $HOST, undef ) {
        my $on = defined $host ? "on $host" : 'on the primary';
        my $r  = on_host( $host, sub { $u->call( 'viewer', 'config-read' ) } );
        ok( $r->{ok}, "on an unsecured site the same account is the operator $on (the probe sees it)" )
            or diag explain $r;
    }
}

# --- reading 2: the rule key is the content-root path, on every door ---------
my ( $s, $d ) = site( users => [
        [ 'sysop',  'sysops', [qw(ui manage_users manage_content manage_config)] ],
        [ 'editor', 'staff',  [qw(ui manage_content)] ],
        [ 'agent',  'agents', [qw(mcp manage_content)] ],
        [ 'davvy',  'davs',   [qw(webdav manage_content)] ],
] );
for my $rule ( [ 'sites/tprf/post', { write => ['@sysops'] } ],
    [ 'sites/tprf/private', { read => ['@sysops'], write => ['@sysops'] } ] )
{
    my $r = $s->call( 'sysop', 'acl-set', query => "action=acl-set&path=$rule->[0]", body => $rule->[1] );
    ok( $r->{ok}, "rule set on $rule->[0]" ) or diag explain $r;
}
my $post = slurp("$d/sites/tprf/post/p.md");

my %tok;
{
    my $out = run_child( [ $^X, "$root/tools/lazysite-users.pl", '--api', '--docroot', $d ],
        stdin => encode_json( { action => 'token', username => 'agent' } ), stderr => 'inherit' )->{out};
    $tok{agent} = ( eval { decode_json($out) } || {} )->{token} // '';
}

sub mcp {
    my ( $tool, $args ) = @_;
    my $body = encode_json( { jsonrpc => '2.0', id => 1, method => 'tools/call',
            params => { name => $tool, arguments => $args } } );
    local %ENV = %ENV;
    delete @ENV{qw(HTTP_X_REMOTE_USER LAZYSITE_AUTH_TRUSTED HTTP_COOKIE LAZYSITE_USERS_TOOL)};
    $ENV{DOCUMENT_ROOT}      = $d;
    $ENV{REQUEST_METHOD}     = 'POST';
    $ENV{CONTENT_LENGTH}     = length $body;
    $ENV{HTTP_AUTHORIZATION} = "Bearer agent:$tok{agent}";
    my $resp = run_child( [ $^X, "$root/lazysite-mcp.pl" ],
        stdin => $body, stderr => 'inherit' )->{out};
    my ($jb) = $resp =~ /\r?\n\r?\n(.*)/s;
    my $j = eval { decode_json( $jb // '' ) } || {};
    return { ok => 0, error => $j->{error}{message} } if $j->{error};
    my $sc = $j->{result}{structuredContent};
    return $sc if ref $sc eq 'HASH';
    return { ok => ( $j->{result}{isError} ? 0 : 1 ), error => $j->{result}{content}[0]{text} };
}

for my $host ( $HOST, undef ) {
    my $on = defined $host ? "on $host" : 'on the primary';
    on_host(
        $host,
        sub {
            my $w = $s->call( 'editor', 'save', query => 'action=save&path=/sites/tprf/post/p.md',
                body => { content => "# overwritten\n" } );
            ok( !$w->{ok}, "manager: a writer the rule does not name is refused the post $on" );
            is( $w->{kind} // '', 'permission', '... by the rule keyed sites/tprf/post' );
            my $r = $s->call( 'editor', 'read', query => 'action=read&path=/sites/tprf/private/x.md' );
            ok( !$r->{ok}, "manager: and refused the read-gated page $on" );
            is( $r->{kind} // '', 'permission', '... by the rule keyed sites/tprf/private' );

            my $m = mcp( 'write_file', { path => '/sites/tprf/post/p.md', content => "# overwritten\n" } );
            ok( !$m->{ok}, "mcp: the same writer is refused the post $on" ) or diag explain $m;
            my $mr = mcp( 'read_file', { path => '/sites/tprf/private/x.md' } );
            ok( !$mr->{ok}, "mcp: and the read-gated page $on" ) or diag explain $mr;

            my $auth = 'Basic ' . encode_base64( 'davvy:pw-davvy-0123456789', '' );
            my $dw   = run_dav( $d, 'PUT', '/sites/tprf/post/p.md',
                HTTP_AUTHORIZATION => $auth, body => "# overwritten\n" );
            is( $dw->{code}, 403, "webdav: the same writer is refused the post $on" );
            my $dr = run_dav( $d, 'GET', '/sites/tprf/private/x.md', HTTP_AUTHORIZATION => $auth );
            is( $dr->{code}, 403, "webdav: and the read-gated page $on" );
        } );
}
is( slurp("$d/sites/tprf/post/p.md"), $post, 'the post is unchanged' );

done_testing();
