#!/usr/bin/perl
# SM1140 (slice C of SM1134, ruled 2026-10-17: "a group's address list limits only
# what the group grants"; "tokens too"): A GROUP, THE MANAGER AND THE MACHINE DOORS
# ARE LIMITED BY THE ADDRESS THE REQUEST COMES FROM.
#
# A group record may carry `addresses` (allow lists) and `addresses_deny` (deny lists).
# When the visitor's address is not allowed for it, that group does not count for the
# request: not its capabilities, not its page access (auth_groups, ACL @group), not
# operator status, and nothing reached through it by nesting. And lazysite.conf
# `manager_addresses` / `manager_addresses_deny` limit /manager/ and the manager API
# for everyone, whatever their groups.
#
# Everything here runs the real CGIs behind a trusted proxy: the connecting peer is
# 127.0.0.1 (listed in trusted_proxies) and the visitor is whatever X-Forwarded-For
# says, 203.0.113.9 (inside, the `office` list) or 198.51.100.9 (outside).
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
use TestHelper     qw(repo_root run_processor);
use ManagerSession qw(new_site);

my $root = repo_root();
plan skip_all => 'manager api missing' unless -f "$root/lazysite-manager-api.pl";
local $ENV{LAZYSITE_PROCESSOR} = "$root/lazysite-processor.pl";

my ( $IN, $OUT ) = ( '203.0.113.9', '198.51.100.9' );
my @ALL = qw(ui api mcp webdav manage_users manage_domains manage_content manage_config write_data);

sub spit { my ( $p, $t ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh; return }
sub slurp { my ($p) = @_; open my $fh, '<', $p or return ''; local $/; my $t = <$fh>; close $fh; return $t }

my $s = new_site( root => $root,
    conf => "control_api_enabled: true\nmcp_enabled: true\nmanager: enabled\ntrusted_proxies: 127.0.0.1\n" );
my $d = $s->docroot;
spit( "$d/index.md",   "---\ntitle: Home\n---\nHome.\n" );
spit( "$d/editors.md", "---\ntitle: Editors\nauth_groups: [g-ed]\n---\nSECRET-EDITORS\n" );
spit( "$d/login.md",   "---\ntitle: Sign in\n---\nSIGN-IN\n" );

# Users and the groups they hold. The groups are plain: the limits are set after,
# through the users tool, the way an operator sets them.
#   ed    g-ed (ui, manage_content)            limited to the office
#   kid   g-kid -> nested in g-par (ui, manage_content)   g-par limited to the office
#   kid2  g-kid2 (limited) -> nested in g-par2 (ui, manage_content)
#   olga  g-ops (the operator group)           limited to the office
#   free  g-free (ui, manage_content)          no limit (the control)
#   tok   g-tok (api, mcp, manage_content)     limited to the office (a token)
#   um    g-um (ui, manage_users)              a manage_users holder, not the operator
my %GROUPS = (
    ed   => [ 'g-ed',   [qw(ui manage_content)] ],
    kid  => [ 'g-kid',  [] ],
    kid2 => [ 'g-kid2', [] ],
    olga => [ 'g-ops',  [qw(ui manage_users manage_content)] ],
    free => [ 'g-free', [qw(ui manage_content)] ],
    tok  => [ 'g-tok',  [qw(api mcp manage_content)] ],
    um   => [ 'g-um',   [qw(ui manage_users)] ],
);
for my $u ( sort keys %GROUPS ) {
    $s->add_user( $u, "pw-$u-0123456789" );
    $s->grant( $u, @{ $GROUPS{$u} }[0], $GROUPS{$u}[1], \@ALL );
}
$s->users( 'group-set', 'g-ops', 'manager', 'on' );
for my $g (qw(g-par g-par2)) {
    $s->users( 'group-create', $g );
    $s->users( 'group-set', $g, $_, 'on' ) for qw(ui manage_content);
}
$s->users( 'group-nest', 'g-kid',  'g-par' );
$s->users( 'group-nest', 'g-kid2', 'g-par2' );

$s->users( 'address-list-set', 'office',  '--kind', 'allow', '--entry', "$IN=office desk", '--entry', '203.0.113.0/24' );
$s->users( 'address-list-set', 'blocked', '--kind', 'deny',  '--entry', $IN );
$s->users( 'group-set', $_->[0], 'addresses', 'office' ) for ( [ 'g-ed' ], [ 'g-par' ], [ 'g-kid2' ], [ 'g-ops' ], [ 'g-tok' ] );

my %tok = map { $_ => ( uapi( { action => 'token', username => $_ } )->{token} // '' ) } qw(tok);

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

# Behind the proxy: the connecting peer is the proxy, the visitor is `$ip`.
sub from {
    my ( $ip, $code ) = @_;
    local $ENV{REMOTE_ADDR}          = '127.0.0.1';
    local $ENV{HTTP_X_FORWARDED_FOR} = $ip;
    return $code->();
}

# A cookie account's manager API call (the wrapper's identity: the account's DIRECT groups).
sub cookie {
    my ( $ip, $who, $action, @o ) = @_;
    return from( $ip, sub { $s->call( $who, $action, groups => [ $GROUPS{$who}[0] ], @o ) } );
}

sub token_api {
    my ( $ip, $who, $action, $nominated ) = @_;
    return from( $ip, sub {
        local %ENV = %ENV;
        delete @ENV{qw(HTTP_X_REMOTE_USER HTTP_X_REMOTE_GROUPS LAZYSITE_AUTH_TRUSTED HTTP_COOKIE HTTP_X_CSRF_TOKEN LAZYSITE_USERS_TOOL)};
        $ENV{LAZYSITE_USERS_TOOL} = "$root/tools/lazysite-users.pl" if $nominated;
        $ENV{DOCUMENT_ROOT}      = $d;
        $ENV{HTTP_AUTHORIZATION} = 'Basic ' . encode_base64( "$who:$tok{$who}", '' );
        $ENV{QUERY_STRING}       = "action=$action";
        $ENV{REQUEST_METHOD}     = 'GET';
        $ENV{CONTENT_LENGTH}     = 0;
        my ( $w, $r );
        my $e   = gensym;
        my $pid = open3( $w, $r, $e, $^X, "$root/lazysite-manager-api.pl" );
        close $w;
        my $out = do { local $/; <$r> };
        waitpid $pid, 0;
        my ($st) = $out =~ /^Status:\s*(\d+)/m;
        my ($jb) = $out =~ /\r?\n\r?\n(.*)/s;
        my $j = eval { decode_json( $jb // '' ) } // { _raw => $out };
        $j->{_status} = $st // 200;
        return $j;
    } );
}

sub mcp_call {
    my ( $ip, $who, $tool, $nominated ) = @_;
    return from( $ip, sub {
        my $body = encode_json( { jsonrpc => '2.0', id => 1, method => 'tools/call',
                params => { name => $tool, arguments => {} } } );
        local %ENV = %ENV;
        delete @ENV{qw(HTTP_X_REMOTE_USER LAZYSITE_AUTH_TRUSTED HTTP_COOKIE LAZYSITE_USERS_TOOL)};
        $ENV{LAZYSITE_USERS_TOOL} = "$root/tools/lazysite-users.pl" if $nominated;
        $ENV{DOCUMENT_ROOT}      = $d;
        $ENV{REQUEST_METHOD}     = 'POST';
        $ENV{CONTENT_LENGTH}     = length $body;
        $ENV{HTTP_AUTHORIZATION} = "Bearer $who:$tok{$who}";
        my ( $out, $in );
        my $pid = open2( $out, $in, $^X, "$root/lazysite-mcp.pl" );
        print {$in} $body;
        close $in;
        my $resp = do { local $/; <$out> };
        waitpid $pid, 0;
        my ($jb) = $resp =~ /\r?\n\r?\n(.*)/s;
        return eval { decode_json( $jb // '' ) } || {};
    } );
}

# The processor, as a page gate sees a cookie session (what the wrapper vouches for).
sub page {
    my ( $ip, $uri, $user, $groups ) = @_;
    return from( $ip, sub {
        run_processor( $d, $uri,
            ( defined $user ? ( LAZYSITE_AUTH_TRUSTED => 1, HTTP_X_REMOTE_USER => $user, HTTP_X_REMOTE_GROUPS => $groups ) : () ) );
    } );
}

sub status { return ( $_[0] =~ /^Status:\s*(\d+)/m )[0] // 200 }

sub held {    # did the call pass the capability gate?
    my ($r) = @_;
    return $r->{ok} ? 1 : 0;
}

subtest 'a group limited to the office grants its capabilities from inside and nothing from outside (cookie)' => sub {
    my $r = cookie( $IN, 'ed', 'pages' );
    ok( held($r), 'inside: manage_content is held' ) or diag( $r->{error} // $r->{_raw} // '' );
    $r = cookie( $OUT, 'ed', 'pages' );
    ok( !held($r), 'outside: refused' ) or diag( explain $r );
    like( $r->{error} // $r->{_raw} // '', qr/manager access|permission|requires/i, '...for the capability and not for another reason' );

    my $free = cookie( $OUT, 'free', 'pages' );
    ok( held($free), 'a group with no limit holds it from outside too (the control)' ) or diag( $free->{error} // '' );
};

subtest 'the manager entry follows the limit even where the wrapper sent no group names' => sub {
    # the cookie `ui` gate also reads the account's capabilities, which the users tool
    # answers whole; they are cut back to the address (narrow_caps_to_request)
    my $r = from( $OUT, sub { $s->call( 'ed', 'pages' ) } );
    ok( !held($r), 'outside: refused with no group header at all' ) or diag( explain $r );
    $r = from( $IN, sub { $s->call( 'ed', 'pages' ) } );
    ok( held($r), 'inside: served' ) or diag( explain $r );
};

subtest 'its page access follows the same limit' => sub {
    my $in = page( $IN, '/editors', 'ed', 'g-ed' );
    is( status($in), 200, 'inside: the auth_groups page is served' ) or diag( substr $in, 0, 300 );
    like( $in, qr/SECRET-EDITORS/, '...with its body' );
    my $out = page( $OUT, '/editors', 'ed', 'g-ed' );
    is( status($out), 403, 'outside: the same session is refused the page' ) or diag( substr $out, 0, 300 );
    unlike( $out, qr/SECRET-EDITORS/, '...and it is not served' );

    # a per-file rule naming the group
    spit( "$d/lazysite/auth/acls.json", encode_json( { 'acl-secret.txt' => { read => ['@g-ed'] } } ) );
    spit( "$d/acl-secret.txt", "ACL-SECRET\n" );
    my $a_in  = page( $IN,  '/acl-secret.txt', 'ed', 'g-ed' );
    my $a_out = page( $OUT, '/acl-secret.txt', 'ed', 'g-ed' );
    like( $a_in, qr/ACL-SECRET/, 'an @group file rule admits the group from inside' ) or diag( substr $a_in, 0, 300 );
    unlike( $a_out, qr/ACL-SECRET/, '...and not from outside' );
    unlink "$d/lazysite/auth/acls.json";
};

subtest 'an operator group limited by address is not the operator from outside' => sub {
    my $set = sub { cookie( $_[0], 'olga', 'address-list-set', body => { name => 'scratch', kind => 'allow', entries => ['192.0.2.1'] }, query => 'action=address-list-set' ) };
    my $r = $set->($IN);
    ok( $r->{ok}, 'inside: the operator writes an address list (an operator-only act)' ) or diag( $r->{error} // $r->{_raw} // '' );
    $r = $set->($OUT);
    ok( !$r->{ok}, 'outside: refused' ) or diag( explain $r );
    my $store = slurp("$d/lazysite/auth/address-lists.json");
    is( () = $store =~ /"scratch"/g, 1, 'and the list was written once, by the inside call' );
};

subtest 'a group nested under a limited group inherits the limit; a limited group lends nothing upward from outside' => sub {
    my $r = cookie( $IN, 'kid', 'pages' );
    ok( held($r), 'kid (in g-kid, nested in the limited g-par): inside, holds what g-par grants' ) or diag( $r->{error} // '' );
    $r = cookie( $OUT, 'kid', 'pages' );
    ok( !held($r), 'outside: g-par is left out, so what it grants is not held' ) or diag( explain $r );

    $r = cookie( $IN, 'kid2', 'pages' );
    ok( held($r), 'kid2 (in the limited g-kid2, nested in g-par2): inside, holds what g-par2 grants' ) or diag( $r->{error} // '' );
    $r = cookie( $OUT, 'kid2', 'pages' );
    ok( !held($r), 'outside: g-kid2 is left out and nothing is reached through it' ) or diag( explain $r );
};

subtest 'a token whose group is limited loses that group from outside (control API and MCP)' => sub {
    my $r = token_api( $IN, 'tok', 'pages' );
    ok( held($r), 'inside: the token holds manage_content' ) or diag( explain $r );
    $r = token_api( $OUT, 'tok', 'pages' );
    ok( !held($r), 'outside: the same token is refused the capability' ) or diag( explain $r );
    like( $r->{error} // '', qr/permission|capab|manage_content|requires/i, '...for lacking it' );

    my $m = mcp_call( $IN, 'tok', 'list_pages' );
    ok( !$m->{error}, 'MCP inside: list_pages is allowed' ) or diag( explain $m );
    $m = mcp_call( $OUT, 'tok', 'list_pages' );
    ok( $m->{error}, 'MCP outside: refused' ) or diag( explain $m );
};

subtest 'the same, where a deployment names its users tool (it answers what the account is granted, not where from)' => sub {
    my $r = token_api( $IN, 'tok', 'pages', 1 );
    ok( held($r), 'control API inside: held' ) or diag( explain $r );
    $r = token_api( $OUT, 'tok', 'pages', 1 );
    ok( !held($r), 'control API outside: the call is cut back to what the address allows' ) or diag( explain $r );
    my $m = mcp_call( $IN, 'tok', 'list_pages', 1 );
    ok( !$m->{error}, 'MCP inside: allowed' ) or diag( explain $m );
    $m = mcp_call( $OUT, 'tok', 'list_pages', 1 );
    ok( $m->{error}, 'MCP outside: refused' ) or diag( explain $m );
};

subtest 'deny wins, on a group' => sub {
    $s->users( 'group-set', 'g-ed', 'addresses_deny', 'blocked' );
    my $r = cookie( $IN, 'ed', 'pages' );
    ok( !held($r), 'an address in the allow list AND the deny list is refused' ) or diag( explain $r );
    uapi( { action => 'group-settings-set', group => 'g-ed', key => 'addresses_deny', value => '' } );
    $r = cookie( $IN, 'ed', 'pages' );
    ok( held($r), 'cleared, it is allowed again' );
};

subtest 'only the operator sets a group\'s addresses; it is audited' => sub {
    my $set = sub {
        my ( $who, $v ) = @_;
        return cookie( $IN, $who, 'users', query => 'action=users',
            body => { action => 'group-settings-set', group => 'g-free', key => 'addresses', value => $v } );
    };
    my $r = $set->( 'um', 'office' );
    ok( !$r->{ok}, 'a manage_users holder is refused' ) or diag( explain $r );
    like( $r->{error} // '', qr/Only a sysop/, '...with the reason' );
    my $gs = decode_json( slurp("$d/lazysite/auth/groups-settings.json") );
    ok( !$gs->{'g-free'}{addresses}, '...and nothing was written' );

    $r = $set->( 'olga', 'office' );
    ok( $r->{ok}, 'the operator sets it' ) or diag( explain $r );
    $gs = decode_json( slurp("$d/lazysite/auth/groups-settings.json") );
    is_deeply( $gs->{'g-free'}{addresses}, ['office'], '...and the record carries it' );
    like( slurp("$d/lazysite/logs/audit.log"), qr/g-free.*addresses=office/, '...audited with the key and the lists' );

    $r = $set->( 'olga', 'Not A Name' );
    ok( !$r->{ok}, 'a bad list name is refused' );
    my $v = cookie( $IN, 'olga', 'users', query => 'action=users', body => { action => 'group-settings-get' } );
    is_deeply( $v->{groups}{'g-free'}{addresses}, ['office'], 'the Groups view serves it' ) or diag( explain $v );
    $set->( 'olga', '' );
    $gs = decode_json( slurp("$d/lazysite/auth/groups-settings.json") );
    ok( !$gs->{'g-free'}{addresses}, 'an empty value clears it' );
};

subtest 'a refused group is audited once an hour per address' => sub {
    my $log = sub { scalar grep { /\| address-refused \| group g-ed \| \Q$OUT\E \|/ } split /\n/, slurp("$d/lazysite/logs/audit.log") };
    cookie( $OUT, 'ed', 'pages' ) for 1 .. 3;
    is( $log->(), 1, 'three requests from one address leave one row' );
    like( slurp("$d/lazysite/logs/audit.log"), qr/\| address-refused \| group g-ed \| \Q$OUT\E \| fail \| web \| not-allowed; lists office/,
        'naming the target, the address, the reason and the list' );
};

subtest 'a faulted address-list store denies' => sub {
    my $good = slurp("$d/lazysite/auth/address-lists.json");
    spit( "$d/lazysite/auth/address-lists.json", '{"office": [' );
    my $r = cookie( $IN, 'ed', 'pages' );
    ok( !held($r), 'a group that names a list is refused even from inside when the store will not read' ) or diag( explain $r );
    my $f = cookie( $IN, 'free', 'pages' );
    ok( held($f), 'a group that names none is untouched' );
    spit( "$d/lazysite/auth/address-lists.json", $good );
    ok( held( cookie( $IN, 'ed', 'pages' ) ), 'repaired, the group counts again' );
};

# ---- the site-wide rule ------------------------------------------------------

sub set_conf {
    my (%k) = @_;
    my $base = "control_api_enabled: true\nmcp_enabled: true\nmanager: enabled\ntrusted_proxies: 127.0.0.1\n";
    spit( "$d/lazysite/lazysite.conf", $base . join( '', map { "$_: $k{$_}\n" } sort keys %k ) );
}

subtest 'manager_addresses limits /manager/ and the manager API for everyone' => sub {
    set_conf( manager_addresses => 'office' );
    my $in  = page( $IN,  '/manager/', 'free', 'g-free' );
    my $out = page( $OUT, '/manager/', 'free', 'g-free' );
    unlike( $in, qr/available from your address/, 'inside: the manager answers' ) or diag( substr $in, 0, 300 );
    is( status($out), 403, 'outside: 403' ) or diag( substr $out, 0, 300 );
    like( $out, qr/This page is not available from your address\./, '...with the ruled sentence, on a page of its own' );
    unlike( $out, qr/office/, '...not naming the list' );

    my $sign_in = page( $OUT, '/login', undef );
    like( $sign_in, qr/SIGN-IN/, 'the sign-in page stays reachable from outside' ) or diag( substr $sign_in, 0, 300 );

    my $api_in  = cookie( $IN,  'free', 'pages' );
    my $api_out = cookie( $OUT, 'free', 'pages' );
    ok( held($api_in), 'the cookie API answers inside' ) or diag( explain $api_in );
    ok( !held($api_out), 'and not outside, whatever the group holds' );
    is( $s->last_status, 403, '...with 403' );
    like( $api_out->{error} // '', qr/This page is not available from your address\./, '...and the same sentence' );

    my $t_in  = token_api( $IN,  'tok', 'pages' );
    my $t_out = token_api( $OUT, 'tok', 'pages' );
    ok( held($t_in), 'a token call from inside is served' ) or diag( explain $t_in );
    is( $t_out->{_status}, 403, 'a token call from outside is 403' ) or diag( explain $t_out );

    like( slurp("$d/lazysite/logs/audit.log"), qr/\| address-refused \| manager \| \Q$OUT\E \|/, 'the page refusal is audited' );
    like( slurp("$d/lazysite/logs/audit.log"), qr/\| address-refused \| manager api \| \Q$OUT\E \|/, 'and the API refusal' );
};

subtest 'the site-wide deny list wins over the allow list' => sub {
    set_conf( manager_addresses => 'office', manager_addresses_deny => 'blocked' );
    is( status( page( $IN, '/manager/', 'free', 'g-free' ) ), 403, 'an address in both is refused' );
    ok( !held( cookie( $IN, 'free', 'pages' ) ), '...at the API too' );
    set_conf();
    ok( held( cookie( $OUT, 'free', 'pages' ) ), 'with the keys gone, the manager answers from anywhere' );
};

subtest 'a faulted store refuses the manager when a rule names a list' => sub {
    my $good = slurp("$d/lazysite/auth/address-lists.json");
    set_conf( manager_addresses => 'office' );
    spit( "$d/lazysite/auth/address-lists.json", 'not json' );
    is( status( page( $IN, '/manager/', 'free', 'g-free' ) ), 403, 'the page refuses from inside' );
    ok( !held( cookie( $IN, 'free', 'pages' ) ), 'and the API' );
    spit( "$d/lazysite/auth/address-lists.json", $good );
    set_conf();
};

subtest 'the Config page keys: names must be real lists of the right kind, and cookie only' => sub {
    my $set = sub {
        my ( $who, $k, $v ) = @_;
        return cookie( $IN, $who, 'config-set', body => { key => $k, value => $v }, query => 'action=config-set' );
    };
    my $r = $set->( 'olga', 'manager_addresses', 'office' );
    ok( $r->{ok}, 'the operator sets manager_addresses to an allow list' ) or diag( explain $r );
    like( slurp("$d/lazysite/lazysite.conf"), qr/^manager_addresses:\s*office$/m, '...and it is in lazysite.conf' );
    $r = $set->( 'olga', 'manager_addresses', 'nope' );
    ok( !$r->{ok}, 'an unknown list is refused' );
    $r = $set->( 'olga', 'manager_addresses', 'blocked' );
    ok( !$r->{ok}, 'a deny list in the allow slot is refused' );
    $r = $set->( 'olga', 'manager_addresses_deny', 'blocked' );
    ok( !$r->{ok}, 'a deny list holding the requester\'s own address is refused: it would lock the setter out' ) or diag( explain $r );
    like( $r->{error} // '', qr/shut your own address out/, '...saying why' );
    $s->users( 'address-list-set', 'outsiders', '--kind', 'deny', '--entry', $OUT );
    $r = $set->( 'olga', 'manager_addresses_deny', 'outsiders' );
    ok( $r->{ok}, 'a deny list that does not hold the setter is accepted' ) or diag( explain $r );
    $r = $set->( 'olga', 'manager_addresses_deny', '' );
    ok( $r->{ok}, 'and clears' ) or diag( explain $r );
    $r = $set->( 'olga', 'manager_addresses', '' );
    ok( $r->{ok}, 'as does the allow key' ) or diag( explain $r );
};

done_testing();
