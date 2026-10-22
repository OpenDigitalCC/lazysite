#!/usr/bin/perl
# SM1140 (slice C of SM1134, ruled: "a group's address list limits only what the
# group grants"; machine doors too): THE DOMAINS A GROUP GRANTS FOLLOW ITS ADDRESS
# LIMIT, AS ITS CAPABILITIES DO.
#
# SM1140's filing, left open: "`narrow_caps_to_request` cuts capabilities only; the
# `dav_scopes` the users tool reports for a cookie caller are the account's whole, as
# before." A domain's allowed_groups is a grant too (SM165: access lives on the
# domain), and it CONFINES as it grants: an account whose only domain comes from a
# group is held to that domain's content root. Two faults followed from the walk
# leaving the group out:
#
#   - where the scopes were resolved in process (WebDAV, a token verified in
#     process) the group's domain dropped out, the account had no allow-entry left,
#     and an empty scope list means UNCONFINED: from outside the group's addresses
#     the account reached every domain on the instance;
#   - where the users tool answered (the cookie manager, a nominated users tool)
#     the scopes were the account's whole: from outside it kept the domain.
#
# Now a group the address is refused for takes the domains it grants with it, and
# the account is never wider for it: what is left is confined to nothing rather than
# to everything. Behind a trusted proxy: peer 127.0.0.1, visitor by X-Forwarded-For.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use JSON::PP       qw(encode_json decode_json);
use MIME::Base64   qw(encode_base64);
use File::Path     qw(make_path);
use TestHelper     qw(repo_root run_dav run_child);
use ManagerSession qw(new_site);

my $root = repo_root();
plan skip_all => 'manager api missing' unless -f "$root/lazysite-manager-api.pl";
local $ENV{LAZYSITE_PROCESSOR} = "$root/lazysite-processor.pl";

my ( $IN, $OUT ) = ( '203.0.113.9', '198.51.100.9' );
my @ALL = qw(ui api mcp webdav manage_users manage_domains manage_content manage_config);

sub spit { my ( $p, $t ) = @_; make_path( $p =~ s{/[^/]+\z}{}r ); open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh; return }

my $s = new_site( root => $root,
    conf => "control_api_enabled: true\nmcp_enabled: true\nwebdav_enabled: true\nmanager: enabled\n"
        . "trusted_proxies: 127.0.0.1\n"
        . "alias_hosts: ext.example.org\n"
        . "alias.ext.example.org.content_root: sites/ext\n"
        . "alias.ext.example.org.allowed_groups: g-dom\n" );
my $d = $s->docroot;
spit( "$d/index.md",        "---\ntitle: Home\n---\nHome.\n" );
spit( "$d/top.md",          "---\ntitle: TOP-PAGE\n---\nTOP-PAGE\n" );
spit( "$d/sites/ext/e.md",  "---\ntitle: EXT-PAGE\n---\nEXT-PAGE\n" );

# dt (an agent account: token, MCP, WebDAV) and dc (a cookie account): their
# capabilities come from g-caps / g-cookie (no limit, no domain); their ONLY domain
# comes from g-dom (no capabilities, limited to the office). So both are confined to
# sites/ext.
my $PW = 'pw-dt-0123456789';
$s->add_user( 'dt', $PW );
$s->grant( 'dt', 'g-caps', [qw(api mcp webdav manage_content)], \@ALL );
$s->grant( 'dt', 'g-dom',  [], \@ALL );
$s->add_user( 'dc', 'pw-dc-0123456789' );
$s->grant( 'dc', 'g-cookie', [qw(ui manage_content)], \@ALL );
$s->users( 'group-add', 'dc', 'g-dom' );
$s->users( 'address-list-set', 'office', '--kind', 'allow', '--entry', '203.0.113.0/24' );
$s->users( 'group-set', 'g-dom', 'addresses', 'office' );

sub uapi {
    my ($p) = @_;
    my $out = run_child( [ $^X, "$root/tools/lazysite-users.pl", '--api', '--docroot', $d ],
        stdin => encode_json($p), stderr => 'inherit' )->{out};
    return eval { decode_json($out) } // {};
}
my $TOK = uapi( { action => 'token', username => 'dt' } )->{token} // '';
ok( length $TOK, 'the account has a token' );

sub from {
    my ( $ip, $code ) = @_;
    local $ENV{REMOTE_ADDR}          = '127.0.0.1';
    local $ENV{HTTP_X_FORWARDED_FOR} = $ip;
    return $code->();
}

sub mcp_read {
    my ( $ip, $path, $nominated ) = @_;
    return from( $ip, sub {
        my $body = encode_json( { jsonrpc => '2.0', id => 1, method => 'tools/call',
                params => { name => 'read_file', arguments => { path => $path } } } );
        local %ENV = %ENV;
        delete @ENV{qw(HTTP_X_REMOTE_USER LAZYSITE_AUTH_TRUSTED HTTP_COOKIE LAZYSITE_USERS_TOOL)};
        $ENV{LAZYSITE_USERS_TOOL} = "$root/tools/lazysite-users.pl" if $nominated;
        $ENV{DOCUMENT_ROOT}      = $d;
        $ENV{REQUEST_METHOD}     = 'POST';
        $ENV{CONTENT_LENGTH}     = length $body;
        $ENV{HTTP_AUTHORIZATION} = "Bearer dt:$TOK";
        my $resp = run_child( [ $^X, "$root/lazysite-mcp.pl" ],
            stdin => $body, stderr => 'inherit' )->{out};
        my ($jb) = $resp =~ /\r?\n\r?\n(.*)/s;
        my $j = eval { decode_json( $jb // '' ) } || {};
        my $text = encode_json( $j->{result} // $j->{error} // {} );
        my $ok   = !$j->{error} && !( $j->{result} && $j->{result}{isError} );
        return { ok => ( $ok ? 1 : 0 ), text => $text };
    } );
}

sub cookie_read {
    my ( $ip, $path ) = @_;
    my $j = from( $ip, sub { $s->call( 'dc', 'read', query => "action=read&path=$path" ) } );
    return { ok => ( $j->{ok} ? 1 : 0 ), text => encode_json($j) };
}

sub dav_get {
    my ( $ip, $path ) = @_;
    my $r = run_dav( $d, 'GET', $path,
        HTTP_AUTHORIZATION   => 'Basic ' . encode_base64( "dt:$TOK", '' ),
        REMOTE_ADDR          => '127.0.0.1',
        HTTP_X_FORWARDED_FOR => $ip );
    return { ok => ( ( $r->{code} // 0 ) == 200 ? 1 : 0 ), text => ( $r->{body} // '' ) . " HTTP $r->{code}" };
}

sub reach {
    my ( $label, $door ) = @_;
    subtest $label => sub {
        my $e = $door->( $IN, 'sites/ext/e.md' );
        ok( $e->{ok}, 'inside: the group\'s domain is reached' ) or diag( $e->{text} );
        like( $e->{text}, qr/EXT-PAGE/, '...with its bytes' );
        my $t = $door->( $IN, 'top.md' );
        ok( !$t->{ok}, 'inside: the account is confined to it (the primary is refused)' ) or diag( $t->{text} );

        $e = $door->( $OUT, 'sites/ext/e.md' );
        ok( !$e->{ok}, 'outside: the group\'s domain is not reached' ) or diag( $e->{text} );
        unlike( $e->{text}, qr/EXT-PAGE/, '...and nothing of it is served' );
        $t = $door->( $OUT, 'top.md' );
        ok( !$t->{ok}, 'outside: and the account is not unconfined by losing it (nothing is reached)' ) or diag( $t->{text} );
        unlike( $t->{text}, qr/TOP-PAGE/, '...the primary is not served' );
    };
    return;
}

reach( 'MCP, the token verified in process', sub { mcp_read( $_[0], $_[1] ) } );
reach( 'MCP, a nominated users tool',        sub { mcp_read( $_[0], $_[1], 1 ) } );
reach( 'WebDAV',                             sub { dav_get( $_[0], "/$_[1]" ) } );
reach( 'manager cookie',                     sub { cookie_read( $_[0], $_[1] ) } );

# The control: with the limit lifted the account reaches its domain from anywhere.
uapi( { action => 'group-settings-set', group => 'g-dom', key => 'addresses', value => '' } );
my $c = mcp_read( $OUT, 'sites/ext/e.md' );
ok( $c->{ok}, 'with no limit on the group, its domain is reached from outside too' ) or diag( $c->{text} );

done_testing();
