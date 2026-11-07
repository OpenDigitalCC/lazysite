#!/usr/bin/perl
# SM1369 X2 (H-7, H-9; ruling 71): ODOO'S TEN ACTIONS AND TWO CAPABILITIES ARE
# THE EXTENSION'S OWN DECLARATION, AND THE WIRE IS WHAT IT WAS.
#
# Before X2 the two doors carried Odoo by hand: ten rows in %GATE and %ACTION,
# ten elsif branches in the manager API, ten entries in MCP's %TOOLS, and
# settle_odoo_writes in @CAP_KEYS, the capability map, the check's list and the
# two grids. What they published was captured at 0.16.7 (t/lib/odoo-wire-0167):
# the control API's rows with their gates, the twins' hints, and the tools/list
# entries an account holding manage_connectors and settle_odoo_writes was
# offered - names, descriptions, schemas and hints. This holds the declared
# rows to that capture, and the listing a group with the SAME grant is offered
# after the top-up ruling 71 gives it (manage_odoo for manage_connectors), so
# an agent connected at 0.16.7 sees the same tools at 0.16.8.
#
# Two differences are the ruling's and are asserted as such: the four
# connection-user actions are gated on manage_odoo rather than manage_connectors
# (every group holding the latter is topped up with the former on next use), and
# each row says whose it is.
#
# And the closed side: Odoo off in lazysite.conf while its declaration is
# indexed answers "this extension is off" from the control API, running nothing;
# the capability map, the check's list and the Groups page's served labels say
# the capabilities are the extension's.
#
# Sabotage: put `settle_odoo_writes` back into @CAP_KEYS and the "no literal"
# subtest fails; change odoo_run's description in extensions/odoo.pl and the
# listing subtest fails.
use strict;
use warnings;
use Test::More;
use File::Path     qw(make_path);
use File::Basename qw(dirname);
use JSON::PP       qw(decode_json encode_json);
use MIME::Base64   qw(encode_base64);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper qw(repo_root run_child site_tempdir link_engine_extensions build_site_index mirror_engine);
use Lazysite::Auth::Settings      ();
use Lazysite::Capabilities        ();
use Lazysite::ControlApi::Actions ();

$ENV{LAZYSITE_LOG_LEVEL} = 'ERROR';
my $root = repo_root();
my $J    = JSON::PP->new->canonical;

sub slurp { open my $fh, '<', $_[0] or die "$_[0]: $!"; local $/; return scalar <$fh> }
sub spit { my ( $p, $c ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $c; close $fh; return }

my $captured_rows = decode_json( slurp("$root/t/lib/odoo-wire-0167/odoo-api-rows.json") );
my $captured_tools = decode_json( slurp("$root/t/lib/odoo-wire-0167/odoo-mcp-tools.json") );

subtest 'the control API rows are what 0.16.7 published, declared by the extension' => sub {
    mirror_engine();
    my %core = map { $_ => 1 } Lazysite::Auth::Settings::core_capability_keys();
    ok( !$core{settle_odoo_writes} && !$core{manage_odoo}, 'the core literal carries neither capability' );
    ok( !Lazysite::ControlApi::Actions::is_core_action('odoo-run'), 'nor the core action table a row' );
    my %ann = Lazysite::ControlApi::Actions::mcp_annotations();
    for my $a ( sort keys %{ $captured_rows->{actions} } ) {
        my $was = $captured_rows->{actions}{$a};
        my $is  = $Lazysite::ControlApi::Actions::ACTION{$a};
        ok( $is, "$a is declared" ) or next;
        is( $is->{extension}, 'odoo', "$a is the extension's" );
        # The ruling's one change: manage_connectors' four rows are manage_odoo's.
        my $gate_was = $was->{gate};
        $gate_was = ['manage_odoo'] if ref $gate_was && "@$gate_was" eq 'manage_connectors';
        my $cookie_was = $was->{cookie_cap};
        $cookie_was = 'manage_odoo' if defined $cookie_was && $cookie_was eq 'manage_connectors';
        is_deeply( $Lazysite::ControlApi::Actions::GATE{$a}, $gate_was, "$a: the gate row" );
        is_deeply( $is->{caps}, ( ref $gate_was ? $gate_was : [] ), "$a: the derived caps" );
        is( $is->{cookie_cap}, $cookie_was, "$a: the cookie gate" );
        is_deeply( $is->{params}, $was->{params}, "$a: the parameters, and where each is read" );
        is( $is->{mcp}, $was->{mcp}, "$a: the twin" );
        for my $f (qw(mutates destructive instance_wide mcp_open_world)) {
            is( $is->{$f} ? 1 : 0, $was->{$f} ? 1 : 0, "$a: $f" );
        }
        is_deeply( $ann{ $was->{mcp} }, $captured_rows->{annotations}{ $was->{mcp} }, "$was->{mcp}: the hints" );
    }
    is( scalar( grep { /\Aodoo-/ } keys %Lazysite::ControlApi::Actions::ACTION ), 10, 'ten rows, no more' );
    is_deeply( [ Lazysite::Capabilities::top_up_from('manage_odoo') ], ['manage_connectors'],
        'manage_odoo is topped up from manage_connectors (ruling 71)' );
    my $map = Lazysite::Capabilities::describe()->{capabilities};
    is( $map->{manage_odoo}{extension}, 'odoo', 'the map says manage_odoo is the extension\'s' );
    is( $map->{settle_odoo_writes}{extension}, 'odoo', 'and settle_odoo_writes' );
    is_deeply( $map->{settle_odoo_writes}{unlocks}{api}, [qw(odoo-unknown-runs odoo-dismiss)], 'with the unlocks the gate gives' );
    ok( !( grep { /\Aodoo/ } @{ $map->{manage_connectors}{unlocks}{api} } ), 'and manage_connectors no longer names an Odoo action' );
    Lazysite::Extensions::Declared::unmirror();
};

# A site with Odoo on, its index built as the upgrade builds it, and a group
# granted what the 0.16.7 capture's account held.
sub site {
    my $d = site_tempdir();
    make_path("$d/lazysite/auth");
    spit( "$d/lazysite/lazysite.conf", "site_name: T\ncontrol_api_enabled: true\nmcp_enabled: true\nextensions:\n  - extensions/odoo.pl\n" );
    spit( "$d/lazysite/auth/.secret", 'c' x 64 );
    chmod 0600, "$d/lazysite/auth/.secret";
    link_engine_extensions($d);
    my $built = build_site_index($d);
    like( $built, qr/declarations indexed: odoo/, 'the build indexed the declaration' );
    return $d;
}

sub users {
    my ( $d, @args ) = @_;
    return run_child( [ $^X, "-I$root/lib", "$root/tools/lazysite-users.pl", '--docroot', $d, @args ], stderr => 'merge' )->{out};
}

sub token {
    my ( $d, $u ) = @_;
    my $r = run_child( [ $^X, "-I$root/lib", "$root/tools/lazysite-users.pl", '--api', '--docroot', $d ],
        stdin => encode_json( { action => 'token', username => $u } ), stderr => 'inherit' );
    return ( eval { decode_json( $r->{out} ) } || {} )->{token} // '';
}

sub mcp {
    my ( $d, $who, $tok, $method, $params ) = @_;
    my $body = encode_json( { jsonrpc => '2.0', id => 1, method => $method, params => $params // {} } );
    local %ENV = %ENV;
    delete @ENV{qw(HTTP_X_REMOTE_USER HTTP_X_REMOTE_GROUPS LAZYSITE_AUTH_TRUSTED HTTP_COOKIE LAZYSITE_USERS_TOOL)};
    $ENV{DOCUMENT_ROOT}      = $d;
    $ENV{REQUEST_METHOD}     = 'POST';
    $ENV{CONTENT_LENGTH}     = length $body;
    $ENV{HTTP_AUTHORIZATION} = "Bearer $who:$tok";
    my $r = run_child( [ $^X, "-I$root/lib", "$root/lazysite-mcp.pl" ], stdin => $body );
    my ($jb) = $r->{out} =~ /\r?\n\r?\n(.*)/s;
    return eval { decode_json( $jb // '' ) } // { _raw => $r->{out}, _err => $r->{err} };
}

sub api {
    my ( $d, $who, $tok, $action, $body ) = @_;
    my $json = defined $body ? encode_json($body) : undef;
    local %ENV = %ENV;
    delete @ENV{qw(HTTP_X_REMOTE_USER HTTP_X_REMOTE_GROUPS LAZYSITE_AUTH_TRUSTED HTTP_COOKIE HTTP_X_CSRF_TOKEN LAZYSITE_USERS_TOOL)};
    $ENV{DOCUMENT_ROOT}      = $d;
    $ENV{HTTP_AUTHORIZATION} = 'Basic ' . encode_base64( "$who:$tok", '' );
    $ENV{QUERY_STRING}       = "action=$action";
    $ENV{REQUEST_METHOD}     = defined $json ? 'POST'       : 'GET';
    $ENV{CONTENT_LENGTH}     = defined $json ? length $json : 0;
    my $r = run_child( [ $^X, "-I$root/lib", "$root/lazysite-manager-api.pl" ], stdin => ( $json // '' ) );
    my ($jb)     = $r->{out} =~ /\r?\n\r?\n(.*)/s;
    my ($status) = $r->{out} =~ /^Status: (\d+)/m;
    my $data = eval { decode_json( $jb // '' ) } // { _raw => $r->{out}, _err => $r->{err} };
    $data->{_status} = $status // 200;
    return $data;
}

subtest 'the same grant is offered the same tools, after the top-up ruling 71 gives it' => sub {
    my $d = site();
    users( $d, 'add',       'op', 'pw123456789-long-enough' );
    users( $d, 'group-add', 'op', 'g-op' );
    users( $d, 'group-set', 'g-op', $_, 'on' ) for qw(mcp api manage_connectors settle_odoo_writes);
    my $gs = decode_json( slurp("$d/lazysite/auth/groups-settings.json") );
    is( $gs->{'g-op'}{manage_odoo}, 1, 'a group holding manage_connectors was topped up with manage_odoo on next use' )
        or diag explain $gs->{'g-op'};
    users( $d, 'group-set', 'g-op', 'manage_odoo', 'off' );
    users( $d, 'group-add', 'op', 'g-op' );
    $gs = decode_json( slurp("$d/lazysite/auth/groups-settings.json") );
    is( $gs->{'g-op'}{manage_odoo}, 0, 'and a 0 an operator wrote is never overwritten' );
    users( $d, 'group-set', 'g-op', 'manage_odoo', 'on' );

    my $tok  = token( $d, 'op' );
    my $list = mcp( $d, 'op', $tok, 'tools/list' );
    my @odoo = sort { $a->{name} cmp $b->{name} } grep { $_->{name} =~ /\Aodoo_/ } @{ $list->{result}{tools} || [] };
    is( scalar @odoo, scalar @$captured_tools, 'the ten Odoo tools are offered' ) or diag explain [ map { $_->{name} } @{ $list->{result}{tools} || [] } ];
    is_deeply( \@odoo, [ sort { $a->{name} cmp $b->{name} } @$captured_tools ],
        'and each is what 0.16.7 listed: name, description, input schema, hints' )
        or diag $J->pretty->encode( \@odoo );

    my $al  = api( $d, 'op', $tok, 'actions-list' );
    my %row = map { $_->{action} => $_ } @{ $al->{actions} || [] };
    is_deeply( [ sort grep { /\Aodoo-/ } keys %row ], [ sort keys %{ $captured_rows->{actions} } ], 'actions-list offers the ten' );
    is_deeply( $row{'odoo-status'}{capabilities}, ['manage_odoo'], 'under the extension\'s own capability' );
    is_deeply( $row{'odoo-run'}{params}, $captured_rows->{actions}{'odoo-run'}{params}, 'with the parameters as published' );

    my $who = decode_json( mcp( $d, 'op', $tok, 'tools/call', { name => 'whoami', arguments => {} } )->{result}{content}[0]{text} );
    ok( $who->{capabilities}{manage_odoo} && $who->{capabilities}{settle_odoo_writes}, 'whoami reports both as held' );
};

subtest 'Odoo off, its declaration indexed: the action is known and answers off' => sub {
    my $d = site();
    users( $d, 'add',       'op',   'pw123456789-long-enough' );
    users( $d, 'group-add', 'op',   'g-op' );
    users( $d, 'group-set', 'g-op', $_, 'on' ) for qw(mcp api manage_odoo);
    my $tok = token( $d, 'op' );
    spit( "$d/lazysite/lazysite.conf", "site_name: T\ncontrol_api_enabled: true\nmcp_enabled: true\n" );
    my $r = api( $d, 'op', $tok, 'odoo-status' );
    is( $r->{kind}, 'disabled', 'the control API refuses as disabled' ) or diag explain $r;
    like( $r->{error}, qr/This extension \(Odoo\) is off/, 'saying which' );
    my $t = decode_json( mcp( $d, 'op', $tok, 'tools/call', { name => 'odoo_status', arguments => {} } )->{result}{content}[0]{text} );
    is( $t->{kind}, 'disabled', 'and so does MCP' );
    my $list = mcp( $d, 'op', $tok, 'tools/list' );
    ok( ( grep { $_->{name} eq 'odoo_status' } @{ $list->{result}{tools} || [] } ), 'the listing does not change with the toggle' );
};

subtest 'the check reads the capabilities from the index, and the grids are served the labels' => sub {
    my $d = site();
    my $out = run_child( [ $^X, "-I$root/lib", "$root/tools/lazysite-check.pl", '--docroot', $d ], stderr => 'merge' )->{out};
    like( $out, qr/the extension index is built \(1 extension declares capabilities or actions, 1 with hooks indexed\)/,
        'the check reports the index' );
    # The failure note: the check says the previous index stands, and why.
    spit( "$d/lazysite/extensions.index.failed", "Sat Nov  7 12:00:00 2026 UTC: the hook index was not written, and the previous one stands: disk full\n" );
    $out = run_child( [ $^X, "-I$root/lib", "$root/tools/lazysite-check.pl", '--docroot', $d ], stderr => 'merge' )->{out};
    like( $out, qr/was not rebuilt by the last build, and the previous one stands \(.*disk full\)/, 'and a failed build, with its reason' );
    unlink "$d/lazysite/extensions.index.failed";
    # The site's hooks index missing an enabled extension's entry.
    my $idx = decode_json( slurp("$d/lazysite/extensions.index.json") );
    delete $idx->{extensions}{odoo};
    spit( "$d/lazysite/extensions.index.json", $J->encode($idx) );
    $out = run_child( [ $^X, "-I$root/lib", "$root/tools/lazysite-check.pl", '--docroot', $d ], stderr => 'merge' )->{out};
    like( $out, qr/declarations are indexed and whose hooks are not: odoo/, 'and an enabled extension whose hooks are not indexed' );

    for my $f (qw(groups users)) {
        my $page = slurp("$root/starter/manager/$f.md");
        unlike( $page, qr/settle_odoo_writes|manage_odoo/, "$f.md names no Odoo capability" );
        like( $page, qr/CAP_LABELS/, "$f.md draws the declared ones from the served labels" );
    }
};

done_testing();
