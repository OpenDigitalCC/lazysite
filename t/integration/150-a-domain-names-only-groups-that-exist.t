#!/usr/bin/perl
# SM1016: every surface that writes a domain's access keys refuses a group (or
# account) the site does not have.
#
# RULED by the release manager on 2026-10-12: "lazysite-domains.pl should
# reject invalid groups". The check is in domain_set (t/unit/manager/284), so
# this drives the two request surfaces that reach it: the manager API's
# domain-set as the Domains page posts it (a cookie session), and the MCP
# domain_set tool. The CLI is t/tools/120 and 121.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use JSON::PP       qw(encode_json decode_json);
use File::Path     qw(make_path);
use TestHelper     qw(repo_root run_child);
use ManagerSession qw(new_site);

my $root = repo_root();
plan skip_all => 'manager api missing' unless -f "$root/lazysite-manager-api.pl";

my @ALL = qw(api ui mcp manage_domains manage_users manage_config manage_content);
my $s = new_site( root => $root, conf => "control_api_enabled: true\nmcp_enabled: true\n" );
my $d = $s->docroot;
make_path("$d/sites/mine");

$s->add_user( 'op', 'pw-op-0123456789' );
$s->grant( 'op', 'ops', [qw(ui manage_domains manage_users manage_config)], \@ALL );
$s->add_user( 'mcm', 'pw-mcm-0123456789' );
$s->grant( 'mcm', 'g-mcm', [qw(mcp manage_domains manage_users)], \@ALL );
$s->add_user( 'ed', 'pw-ed-0123456789' );
$s->grant( 'ed', 'staff', ['ui'], \@ALL );

sub conf { open my $fh, '<', "$d/lazysite/lazysite.conf" or return ''; local $/; return <$fh> }

sub uapi {
    my ($p) = @_;
    my $out = run_child( [ $^X, "$root/tools/lazysite-users.pl", '--api', '--docroot', $d ],
        stdin => encode_json($p), stderr => 'inherit' )->{out};
    return eval { decode_json($out) } // {};
}
my $token = uapi( { action => 'token', username => 'mcm' } )->{token} // '';

sub mcp {
    my ( $tool, $args ) = @_;
    my $body = encode_json( { jsonrpc => '2.0', id => 1, method => 'tools/call',
            params => { name => $tool, arguments => $args } } );
    local %ENV = %ENV;
    delete @ENV{qw(HTTP_X_REMOTE_USER LAZYSITE_AUTH_TRUSTED HTTP_COOKIE LAZYSITE_USERS_TOOL)};
    $ENV{DOCUMENT_ROOT}      = $d;
    $ENV{REQUEST_METHOD}     = 'POST';
    $ENV{CONTENT_LENGTH}     = length $body;
    $ENV{HTTP_AUTHORIZATION} = "Bearer mcm:$token";
    my $resp = run_child( [ $^X, "$root/lazysite-mcp.pl" ],
        stdin => $body, stderr => 'inherit' )->{out};
    my ($jb) = $resp =~ /\r?\n\r?\n(.*)/s;
    my $j = eval { decode_json( $jb // '' ) } || {};
    return { ok => 0, error => $j->{error}{message} } if $j->{error};
    return $j->{result}{structuredContent} || { ok => 0, error => 'no structured content' };
}

ok( $s->call( 'op', 'domain-add', body => { host => 'mine.example.org', content_root => 'sites/mine' } )->{ok},
    'a domain' );

# --- the manager API, as the Domains page posts it ------------------------------
{
    my $r = $s->call( 'op', 'domain-set',
        body => { host => 'mine.example.org', key => 'allowed_groups', value => 'g-mcm, @staff' } );
    ok( $r->{ok}, 'domain-set accepts groups the site has, with or without @' )
        or diag( $r->{error} // '' );

    my $before = conf();
    $r = $s->call( 'op', 'domain-set',
        body => { host => 'mine.example.org', key => 'allowed_groups', value => 'g-mcm, staff, stafff' } );
    ok( !$r->{ok}, 'domain-set refuses a group the site does not have' );
    like( $r->{error} // '', qr/No group \@stafff on this site/, 'naming it' );
    is( conf(), $before, 'and changes nothing' );

    $r = $s->call( 'op', 'domain-set',
        body => { host => 'mine.example.org', key => 'locked_users', value => 'ed, edd' } );
    ok( !$r->{ok}, 'and an account the site does not have' );
    like( $r->{error} // '', qr/No account edd on this site/, 'naming it' );
}

# --- MCP domain_set -----------------------------------------------------------------
{
    my $before = conf();
    my $r      = mcp( 'domain_set',
        { host => 'mine.example.org', key => 'allowed_groups', value => 'g-mcm, staff, @ghost' } );
    ok( !$r->{ok}, 'MCP domain_set refuses a group the site does not have' );
    like( $r->{error} // '', qr/No group \@ghost on this site/, 'naming it' );
    is( conf(), $before, 'and changes nothing' );

    $r = mcp( 'domain_set', { host => 'mine.example.org', key => 'allowed_groups', value => 'g-mcm, @ops' } );
    ok( $r->{ok}, 'and accepts a group the site has' ) or diag( $r->{error} // '' );
}

done_testing();
