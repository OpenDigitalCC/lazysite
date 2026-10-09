#!/usr/bin/perl
# SM943 ruling 2 (2026-10-09): the STRUCTURED nav read - control-API nav-read,
# MCP read_nav - needs no capability beyond the surface's base access, the same
# on both surfaces, and reaches only the caller's own domains (SM976). Writing
# (nav-save, set_nav) stays manage_nav; a WebDAV GET of the raw nav file stays
# manage_nav; manage_content grants nothing nav-specific.
#
# Each caller below holds the channel and nothing nav-related, unless named.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use JSON::PP       qw(encode_json decode_json);
use IPC::Open2     qw(open2);
use IPC::Open3     qw(open3);
use Symbol         qw(gensym);
use MIME::Base64   qw(encode_base64);
use File::Path     qw(make_path);
use TestHelper     qw(repo_root run_dav);
use ManagerSession qw(new_site);

my $root = repo_root();
plan skip_all => 'manager api missing' unless -f "$root/lazysite-manager-api.pl";

my @ALL = qw(api ui mcp webdav manage_domains manage_users manage_content manage_nav);
my $s   = new_site( root => $root,
    conf => "control_api_enabled: true\nmcp_enabled: true\nwebdav_enabled: true\n" );
my $d = $s->docroot;
make_path( "$d/sites/mine", "$d/sites/other" );

$s->add_user('op');
$s->grant( 'op', 'g-op', [qw(ui manage_domains manage_users manage_nav)], \@ALL );
for my $x ( [ 'mine.example.org', 'sites/mine' ], [ 'other.example.org', 'sites/other' ] ) {
    ( my $n = $x->[0] ) =~ s/\..*//;
    ok( $s->call( 'op', 'domain-add', body => { host => $x->[0], content_root => $x->[1],
                nav_file => "lazysite/nav-$n.conf" } )->{ok}, "set up $x->[0]" );
    ok( $s->call( 'op', 'nav-save', body => { host => $x->[0], items => [ { label => "Nav-$n", url => '/' } ] } )->{ok},
        "and its nav" );
}

# Who: a token, a cookie manager, an MCP grant and a WebDAV account, each holding
# the channel only (or manage_content only), scoped to mine.
my %CAPS = (
    tk  => [qw(api)],
    tkc => [qw(api manage_content)],
    ck  => [qw(ui)],
    mc  => [qw(mcp)],
    mcc => [qw(mcp manage_content)],
    dv  => [qw(webdav manage_content)],
);
for my $u ( sort keys %CAPS ) {
    $s->add_user( $u, "pw-$u-0123456789" );
    $s->grant( $u, "g-$u", $CAPS{$u}, \@ALL );
}
ok( $s->call( 'op', 'domain-set', body => { host => 'mine.example.org', key => 'allowed_groups',
            value => join ', ', map { "g-$_" } sort keys %CAPS } )->{ok}, 'all of them scoped to mine' );

sub uapi {
    my ($p) = @_;
    my ( $o, $i );
    my $pid = open2( $o, $i, $^X, "$root/tools/lazysite-users.pl", '--api', '--docroot', $d );
    print {$i} encode_json($p);
    close $i;
    my $out = do { local $/; <$o> };
    waitpid $pid, 0;
    return eval { decode_json($out) } // {};
}
my %tok = map { $_ => ( uapi( { action => 'token', username => $_ } )->{token} // '' ) } qw(tk tkc mc mcc);

sub api {
    my ( $who, $query, $body ) = @_;
    return $s->call( $who, '', query => $query, ( defined $body ? ( body => $body ) : () ) )
        if $who eq 'ck';
    my $json = defined $body ? encode_json($body) : undef;
    local %ENV = %ENV;
    delete @ENV{qw(HTTP_X_REMOTE_USER LAZYSITE_AUTH_TRUSTED HTTP_COOKIE HTTP_X_CSRF_TOKEN LAZYSITE_USERS_TOOL)};
    $ENV{DOCUMENT_ROOT}      = $d;
    $ENV{HTTP_AUTHORIZATION} = 'Basic ' . encode_base64( "$who:$tok{$who}", '' );
    $ENV{QUERY_STRING}       = $query;
    $ENV{REQUEST_METHOD}     = defined $json ? 'POST'       : 'GET';
    $ENV{CONTENT_LENGTH}     = defined $json ? length $json : 0;
    my ( $w, $r );
    my $pid = open3( $w, $r, gensym, $^X, "$root/lazysite-manager-api.pl" );
    print {$w} ( $json // '' );
    close $w;
    my $out = do { local $/; <$r> };
    waitpid $pid, 0;
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
    my ( $o, $i );
    my $pid = open2( $o, $i, $^X, "$root/lazysite-mcp.pl" );
    print {$i} $body;
    close $i;
    my $resp = do { local $/; <$o> };
    waitpid $pid, 0;
    my ($jb) = $resp =~ /\r?\n\r?\n(.*)/s;
    my $j = eval { decode_json( $jb // '' ) } || {};
    return { ok => 0, error => $j->{error}{message} } if $j->{error};
    return $j->{result}{structuredContent} || { ok => 0, error => 'no structured content' };
}
sub labels { return join ',', map { $_->{label} } @{ $_[0]{items} || [] } }

subtest 'the structured read: no capability, its own domains only, on both surfaces' => sub {
    for my $who (qw(tk tkc ck)) {
        my $r = api( $who, 'action=nav-read&host=mine.example.org' );
        ok( $r->{ok}, "API $who reads its own domain's nav" ) or diag( $r->{error} // $r->{_raw} );
        is( labels($r), 'Nav-mine', '...and gets it' );
        ok( !api( $who, 'action=nav-read&host=other.example.org' )->{ok}, "API $who: not another domain's" );
        ok( !api( $who, 'action=nav-read' )->{ok}, "API $who: nor the primary's" );
    }
    for my $who (qw(mc mcc)) {
        my $r = mcp( $who, 'read_nav', { host => 'mine.example.org' } );
        ok( $r->{ok}, "MCP $who reads its own domain's nav" ) or diag( $r->{error} );
        is( labels($r), 'Nav-mine', '...and gets it' );
        ok( !mcp( $who, 'read_nav', { host => 'other.example.org' } )->{ok}, "MCP $who: not another domain's" );
        ok( !mcp( $who, 'read_nav', {} )->{ok}, "MCP $who: nor the primary's" );
    }
};

subtest 'the write stays manage_nav, and manage_content grants nothing nav-specific' => sub {
    my $items = [ { label => 'Taken', url => '/' } ];
    for my $who (qw(tk tkc ck)) {
        ok( !api( $who, 'action=nav-save', { host => 'mine.example.org', items => $items } )->{ok},
            "API $who cannot nav-save, even its own domain" );
    }
    for my $who (qw(mc mcc)) {
        ok( !mcp( $who, 'set_nav', { host => 'mine.example.org', items => $items } )->{ok},
            "MCP $who cannot set_nav, even its own domain" );
    }
    my $auth = 'Basic ' . encode_base64( 'dv:pw-dv-0123456789', '' );
    is( run_dav( $d, 'GET', '/lazysite/nav-mine.conf', HTTP_AUTHORIZATION => $auth )->{code}, 403,
        'WebDAV GET of the raw nav file still needs manage_nav' );
    my $nav = do { open my $fh, '<', "$d/lazysite/nav-mine.conf" or die $!; local $/; <$fh> };
    unlike( $nav, qr/Taken/, 'and nothing was written' );
};

done_testing();
