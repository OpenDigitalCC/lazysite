#!/usr/bin/perl
# SM1370 (ruling 121): A TOKEN'S CAPABILITIES FOLLOW ITS ACCOUNT'S CURRENT GRANT
# AT EACH REQUEST. A grant made at the account reaches a token issued before it,
# a grant taken away is refused on that token at once, and what confines the
# token (its domain scope) still confines it when the account's grant widens.
#
# MEASURED BEFORE ANY CHANGE: nothing on the pairing exchange, the token mint or
# the OAuth store copies a capability into the credential. lzs_ tokens verify
# through Auth::Verify::verify_credential, which resolves the account's groups
# afresh (caps_for); an OAuth access token maps to a partner and partner-caps
# resolves that partner afresh; the manager API rebuilds %token_caps on every
# request. So the three behaviours below already held on the three token doors,
# and this test pins them there - each door, each direction - so a cache or a
# snapshot added later fails here. The one behaviour SM1370 adds is the `grant`
# block both whoamis now carry, which says so to the agent (subtest 4: fails
# with the block reverted).
use strict;
use warnings;
use Test::More;
use File::Path   qw(make_path);
use JSON::PP     qw(encode_json decode_json);
use MIME::Base64 qw(encode_base64);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper qw(repo_root site_tempdir grant_caps revoke_caps run_child);
use Lazysite::Auth::OAuth ();

my $root  = repo_root();
my $utool = "$root/tools/lazysite-users.pl";
my $mapi  = "$root/lazysite-manager-api.pl";
my $mcp   = "$root/lazysite-mcp.pl";

my $d = site_tempdir();
make_path( "$d/lazysite/auth", "$d/sites/a", "$d/sites/b" );
sub put {
    my ( $rel, $text ) = @_;
    open my $f, '>', "$d/$rel" or die "$rel: $!";
    print {$f} $text;
    close $f;
}
put( 'lazysite/lazysite.conf', "site_name: T\ncontrol_api_enabled: true\nmcp_enabled: true\n"
        . "alias_hosts: a.test, b.test\n"
        . "alias.a.test.content_root: sites/a\nalias.a.test.allowed_groups: role-scoped\n"
        . "alias.b.test.content_root: sites/b\nalias.b.test.allowed_groups: nobody-here\n" );
put( 'lazysite/auth/groups-settings.json', '{"admins":{"label":"Admins","ui":1,"manage_users":1}}' );
put( 'lazysite/auth/.secret', ( 'sekret' x 6 ) . "\n" );
put( 'sites/a/page.md', "---\ntitle: A\n---\nA.\n" );
put( 'sites/b/page.md', "---\ntitle: B\n---\nB.\n" );

sub uapi {
    my ($p) = @_;
    my $out = run_child( [ $^X, $utool, '--api', '--docroot', $d ],
        stdin => encode_json($p), stderr => 'inherit' )->{out};
    return eval { decode_json($out) } // { _raw => $out };
}

sub mapi {
    my (%o) = @_;
    my $body = delete $o{body};
    local %ENV = %ENV;
    $ENV{DOCUMENT_ROOT}       = $d;
    $ENV{LAZYSITE_USERS_TOOL} = $utool;
    $ENV{REQUEST_METHOD}      = $o{REQUEST_METHOD} || 'GET';
    $ENV{CONTENT_LENGTH}      = defined $body ? length($body) : 0;
    delete $ENV{HTTP_X_REMOTE_USER};
    for ( keys %o ) { $ENV{$_} = $o{$_} if defined $o{$_} }
    my $out = run_child( [ $^X, $mapi ], stdin => ( defined $body ? $body : '' ) )->{out};
    my ($jb) = $out =~ /\r?\n\r?\n(.*)/s;
    return eval { decode_json( $jb // '' ) } // { _raw => $out };
}

sub mcp_call {
    my ( $auth, $name, $args ) = @_;
    my $body = encode_json( { jsonrpc => '2.0', id => 1, method => 'tools/call',
            params => { name => $name, arguments => $args || {} } } );
    local %ENV = %ENV;
    $ENV{DOCUMENT_ROOT}       = $d;
    $ENV{REQUEST_METHOD}      = 'POST';
    $ENV{CONTENT_LENGTH}      = length $body;
    $ENV{LAZYSITE_USERS_TOOL} = $utool;
    $ENV{HTTP_AUTHORIZATION}  = $auth;
    my $resp = run_child( [ $^X, $mcp ], stdin => $body, stderr => 'inherit' )->{out};
    my ($jb) = $resp =~ /\r?\n\r?\n(.*)/s;
    return ( defined $jb && length $jb ) ? eval { decode_json($jb) } : undef;
}
sub mcp_ok {
    my $r = shift;
    return 0 unless $r && !$r->{error} && $r->{result};
    my $s = $r->{result}{structuredContent};
    return ( $s && $s->{ok} ) ? 1 : 0;
}
sub mcp_refused { my $r = shift; return ( $r && $r->{error} && $r->{error}{code} == -32002 ) ? 1 : 0 }

# The account, its interactive login off (an agent), and one token minted
# while it held nothing but its channels.
uapi( { action => 'add', username => 'agent', password => 'x-long-enough' } );
uapi( { action => 'settings-set', username => 'agent', key => 'ui', value => 'off' } );
grant_caps( $d, 'agent', 'api', 'mcp' );
my $tok = uapi( { action => 'token', username => 'agent' } )->{token};
ok( $tok, 'a token is minted before the grant' );
my $basic  = 'Basic ' . encode_base64( "agent:$tok", '' );
my $bearer = "Bearer agent:$tok";

$Lazysite::Auth::OAuth::LAZYSITE_DIR = "$d/lazysite";
my ($oauth) = Lazysite::Auth::OAuth::issue_token('agent');
my $obearer = "Bearer $oauth";

subtest '1. a grant added at the account reaches the existing token' => sub {
    ok( !mapi( QUERY_STRING => 'action=form-list', HTTP_AUTHORIZATION => $basic )->{ok},
        'control API: form-list refused before the grant' );
    ok( mcp_refused( mcp_call( $bearer, 'form_list' ) ), 'MCP bearer: form_list refused before' );
    ok( mcp_refused( mcp_call( $obearer, 'form_list' ) ), 'MCP OAuth: form_list refused before' );

    grant_caps( $d, 'agent', 'read_submissions' );

    my $r = mapi( QUERY_STRING => 'action=form-list', HTTP_AUTHORIZATION => $basic );
    ok( $r->{ok}, 'control API: the same token is admitted after the grant' ) or diag explain $r;
    ok( mcp_ok( mcp_call( $bearer, 'form_list' ) ), 'MCP bearer: admitted, no new pairing key' );
    ok( mcp_ok( mcp_call( $obearer, 'form_list' ) ), 'MCP OAuth: admitted, no reconnect' );
};

subtest '2. a grant removed at the account is refused on the token at once' => sub {
    revoke_caps( $d, 'agent', 'read_submissions' );
    ok( !mapi( QUERY_STRING => 'action=form-list', HTTP_AUTHORIZATION => $basic )->{ok},
        'control API: refused on the very next request' );
    ok( mcp_refused( mcp_call( $bearer, 'form_list' ) ), 'MCP bearer: refused at once' );
    ok( mcp_refused( mcp_call( $obearer, 'form_list' ) ), 'MCP OAuth: refused at once, refresh or not' );
};

subtest '3. a token confined to a domain stays confined when the account widens' => sub {
    # The account's reach: a.test only, through the group the domain allows.
    grant_caps( $d, 'agent', 'manage_content' );
    {
        open my $fh, '>>', "$d/lazysite/auth/groups" or die $!;
        print {$fh} "role-scoped: agent\n";
        close $fh;
    }
    ok( mcp_ok( mcp_call( $bearer, 'read_file', { path => '/sites/a/page.md' } ) ),
        'inside its domain: read' );
    ok( mcp_refused( mcp_call( $bearer, 'read_file', { path => '/sites/b/page.md' } ) ),
        'outside it: refused' );

    # The account widens: more capabilities, and the operator's design set.
    grant_caps( $d, 'agent', 'manage_content', 'manage_nav', 'manage_forms', 'manage_themes' );
    ok( mcp_refused( mcp_call( $bearer, 'read_file', { path => '/sites/b/page.md' } ) ),
        'MCP bearer: still refused outside its domain after the widening' );
    ok( mcp_refused( mcp_call( $obearer, 'read_file', { path => '/sites/b/page.md' } ) ),
        'MCP OAuth: likewise' );
    ok( mcp_refused( mcp_call( $bearer, 'write_file',
                { path => '/sites/b/page.md', content => "---\ntitle: B\n---\nX.\n" } ) ),
        'MCP bearer: a write outside its domain is still refused' );
    like( do { open my $f, '<', "$d/sites/b/page.md" or die $!; local $/; <$f> }, qr/\AB\.|B\.\n/,
        '...and the page is untouched' );
};

subtest '4. both whoamis say where the grant comes from' => sub {
    my $m = mcp_call( $bearer, 'whoami' );
    my $g = $m && $m->{result} ? $m->{result}{structuredContent}{grant} : undef;
    is( ref $g eq 'HASH' ? $g->{source} : undef, 'account', 'MCP whoami: grant.source is the account' );
    like( ref $g eq 'HASH' ? $g->{note} : '', qr/next request.*no new pairing key/s,
        'and the note says a change applies from the next request, with no new pairing key' );
    my $a = mapi( QUERY_STRING => 'action=whoami&extensions=0', HTTP_AUTHORIZATION => $basic );
    is( ref $a->{grant} eq 'HASH' ? $a->{grant}{source} : undef, 'account',
        'control-API whoami: the same block' ) or diag explain $a;
};

done_testing();
