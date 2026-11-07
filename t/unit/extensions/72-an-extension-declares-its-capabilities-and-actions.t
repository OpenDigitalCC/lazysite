#!/usr/bin/perl
# SM1369 X2 (H-7, H-9; rulings 71, 135): AN EXTENSION DECLARES ITS CAPABILITIES
# AND ITS ACTIONS, AND CORE'S TABLES CARRY THEM FROM THE INDEX.
#
# A fixture extension (probe) declares one capability with its metadata and
# two control-API actions with MCP twins - one gated on that capability, one
# ALWAYS with its reason - and the handlers in its own payload lib. Enabling it
# builds the index with a `declared` view; the mirror fills @CAP_KEYS, the
# capability map and the gate from it, and both doors - the real manager API
# and the real MCP server, as subprocesses - dispatch the action through the
# one table-driven branch to the extension's handler, with the caller's
# identity and the declared parameters. A capability the mirror adds is one a
# group can be given, and whoami reports.
#
# And what the index build refuses, each by name: a row with no gate; an ALWAYS
# row with no reason; a row whose name is not the extension's; a capability or
# an action that shadows a core name; an owned capability nobody describes; a
# twin whose schema requires what the action does not. An extension whose
# declaration fails is not enabled (X1's C-7), so none of it reaches a door.
#
# And the closed side at the call: the extension off in lazysite.conf while
# the index still lists it (a disable whose rebuild failed) answers "this
# extension is off" from both doors, running nothing; an extension on whose
# hooks are not indexed answers "cannot run now" and names the rebuild.
#
# Sabotage: take the enabled check out of run_action and the "off" subtest
# runs the handler; take the gate row check out of _validate_api_actions and
# the "no gate" row is indexed.
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
use TestHelper                    qw(site_tempdir repo_root run_child);
use Lazysite::Manager::Extensions qw(action_extension_enable action_extension_disable extension_enabled);
use Lazysite::Extensions::Hooks    qw(read_index);
use Lazysite::Extensions::Declared qw(mirror unmirror run_action);
use Lazysite::Auth::Settings       ();
use Lazysite::Capabilities         ();
use Lazysite::ControlApi::Actions  ();

$ENV{LAZYSITE_LOG_LEVEL} = 'ERROR';
my $root = repo_root();

sub spit { my ( $p, $c ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $c; close $fh; return }
sub slurp { open my $fh, '<', $_[0] or die "$_[0]: $!"; local $/; return scalar <$fh> }

sub write_extension {
    my ( $path, $desc ) = @_;
    my $json = JSON::PP->new->canonical->encode($desc);
    $json =~ s/'/'\\''/g;
    spit( $path, "#!/usr/bin/perl\nprint q'$json' if \@ARGV && \$ARGV[0] eq '--describe';\nexit 0;\n" );
    chmod 0755, $path or die $!;
    return;
}

my $F = JSON::PP::false;
my ( $M, $N ) = ( '', 0 );

# The declaration under test, with one row or one capability replaced.
sub declaration {
    my (%over) = @_;
    my $cap = {
        section => 'Operations', label => 'Probe things', title => 'Probe the probe.',
        grants => 'Ask the probe extension what it was handed.', top_up_from => ['manage_connectors'],
        unlocks => { ui => ['the probe panel'] },
    };
    my @rows = (
        { name => 'probe-echo', mcp => 'probe_echo', handler => "${M}::Actions::echo",
            gate => ['probe_things'], cookie_cap => 'probe_things', mutates => 1,
            params => [ { name => 'word', in => 'body', required => 1 }, { name => 'times', in => 'query' } ],
            description => 'Echo a word.',
            input_schema => { type => 'object', properties => { word => { type => 'string' }, times => { type => 'integer' } },
                required => ['word'], additionalProperties => $F },
        },
        { name => 'probe-who', mcp => 'probe_who', handler => "${M}::Actions::who",
            gate => 'ALWAYS', always_reason => 'it answers only who the caller is, which the caller already knows',
            params       => [], description => 'Who am I, to the probe.',
            input_schema => { type => 'object', properties => {}, additionalProperties => $F },
        },
    );
    return {
        id => 'probe', name => 'Probe', contract => 1,
        config_file => 'lazysite/probe.conf', config_schema => [ { key => 'note', label => 'Note', type => 'text' } ],
        owns => {
            capabilities => $over{capabilities} // ['probe_things'],
            hooks        => {
                capability_info => $over{capability_info} // { probe_things => $cap },
                api_actions     => $over{api_actions}     // \@rows,
                refusal_kinds   => { 'probe-tired' => '429 Too Many Requests' },
            },
        },
    };
}

sub fixture {
    $M = 'Probe' . ++$N;
    my $d    = site_tempdir();
    my $base = dirname($d);
    make_path( "$d/lazysite/auth", "$base/extensions/probe/lib/${M}" );
    spit( "$d/lazysite/lazysite.conf", "site_name: T\ncontrol_api_enabled: true\nmcp_enabled: true\n" );
    write_extension( "$base/extensions/probe.pl", declaration() );
    spit( "$base/extensions/probe/lib/${M}/Actions.pm", <<"PM" );
package ${M}::Actions;
use strict; use warnings;
sub echo { my (\$p, \$c) = \@_; return { ok => 1, word => \$p->{word}, times => \$p->{times}, user => \$c->{user},
    channel => \$c->{channel}, docroot => \$c->{docroot}, action => \$c->{action}, extension => \$c->{extension},
    has_cap => (\$c->{caps}{probe_things} ? 1 : 0) } }
sub who { my (\$p, \$c) = \@_; return { ok => 1, user => \$c->{user}, channel => \$c->{channel} } }
1;
PM
    $Lazysite::Manager::Extensions::DOCROOT = $d;
    unmirror();
    return ( $base, $d );
}

sub index_file { return "$_[0]/lazysite/extensions.index.json" }

# THE ACCOUNTS, THROUGH THE USERS TOOL, which reads the site's index too: `op`
# is granted the declared capability by name (a grant the tool admits only
# because the mirror made it a capability - H-7's "grantable"), `tk` holds
# the channels alone. Each gets a token, and both doors verify it against the
# store, as in production.
my %TOKEN;

sub users {
    my ( $d, @args ) = @_;
    my $r = run_child( [ $^X, "-I$root/lib", "$root/tools/lazysite-users.pl", '--docroot', $d, @args ], stderr => 'merge' );
    return $r->{out};
}

sub users_api {
    my ( $d, $p ) = @_;
    my $r = run_child( [ $^X, "-I$root/lib", "$root/tools/lazysite-users.pl", '--api', '--docroot', $d ],
        stdin => encode_json($p), stderr => 'inherit' );
    return eval { decode_json( $r->{out} ) } // {};
}

sub accounts {
    my ($d) = @_;
    spit( "$d/lazysite/auth/.secret", 'c' x 64 );
    chmod 0600, "$d/lazysite/auth/.secret";
    for my $u (qw(op tk)) {
        users( $d, 'add',       $u,     'pw123456789-long-enough' );
        users( $d, 'group-add', $u,     "g-$u" );
        users( $d, 'group-set', "g-$u", $_, 'on' ) for qw(api mcp);
    }
    my $out = users( $d, 'group-set', 'g-op', 'probe_things', 'on' );
    like( $out, qr/\bon\b|granted|probe_things/i, 'the users tool grants the declared capability by name' ) or diag $out;
    for my $u (qw(op tk)) { $TOKEN{$u} = users_api( $d, { action => 'token', username => $u } )->{token} // '' }
    ok( length $TOKEN{op} && length $TOKEN{tk}, 'tokens minted' );
    return;
}

sub api {
    my ( $d, $who, $action, $body, $query ) = @_;
    my $json = defined $body ? encode_json($body) : undef;
    local %ENV = %ENV;
    delete @ENV{qw(HTTP_X_REMOTE_USER HTTP_X_REMOTE_GROUPS LAZYSITE_AUTH_TRUSTED HTTP_COOKIE HTTP_X_CSRF_TOKEN LAZYSITE_USERS_TOOL)};
    $ENV{DOCUMENT_ROOT}      = $d;
    $ENV{HTTP_AUTHORIZATION} = 'Basic ' . encode_base64( "$who:$TOKEN{$who}", '' );
    $ENV{QUERY_STRING}       = $query // "action=$action";
    $ENV{REQUEST_METHOD}     = defined $json ? 'POST'       : 'GET';
    $ENV{CONTENT_LENGTH}     = defined $json ? length $json : 0;
    my $r = run_child( [ $^X, "-I$root/lib", "$root/lazysite-manager-api.pl" ], stdin => ( $json // '' ) );
    my ($jb)     = $r->{out} =~ /\r?\n\r?\n(.*)/s;
    my ($status) = $r->{out} =~ /^Status: (\d+)/m;
    my $data = eval { decode_json( $jb // '' ) } // { _raw => $r->{out}, _err => $r->{err} };
    $data->{_status} = $status // 200;
    return $data;
}

my $rpc = 0;

sub mcp {
    my ( $d, $who, $method, $params ) = @_;
    my $body = encode_json( { jsonrpc => '2.0', id => ++$rpc, method => $method, params => $params // {} } );
    local %ENV = %ENV;
    delete @ENV{qw(HTTP_X_REMOTE_USER HTTP_X_REMOTE_GROUPS LAZYSITE_AUTH_TRUSTED HTTP_COOKIE LAZYSITE_USERS_TOOL)};
    $ENV{DOCUMENT_ROOT}      = $d;
    $ENV{REQUEST_METHOD}     = 'POST';
    $ENV{CONTENT_LENGTH}     = length $body;
    $ENV{HTTP_AUTHORIZATION} = "Bearer $who:$TOKEN{$who}";
    my $r = run_child( [ $^X, "-I$root/lib", "$root/lazysite-mcp.pl" ], stdin => $body );
    my ($jb) = $r->{out} =~ /\r?\n\r?\n(.*)/s;
    return eval { decode_json( $jb // '' ) } // { _raw => $r->{out}, _err => $r->{err} };
}

sub tool_result {
    my ($resp) = @_;
    my $t      = $resp->{result}{content}[0]{text} // '';
    return eval { decode_json($t) } // { _text => $t, _error => $resp->{error} };
}

subtest 'enabled, the declaration is indexed, and the mirror fills the tables from it' => sub {
    my ( $base, $d ) = fixture();
    my $r = action_extension_enable('extensions/probe.pl');
    ok( $r->{ok}, 'enabled' ) or diag explain $r;
    is_deeply( $r->{index}{indexed},  ['probe'], 'hooks indexed' );
    is_deeply( $r->{index}{declared}, ['probe'], 'and the declaration' );
    my $idx = decode_json( slurp( index_file($d) ) );
    is_deeply( $idx->{declared}{probe}{capabilities}, ['probe_things'], 'the index carries the capability' );
    is( scalar @{ $idx->{declared}{probe}{api_actions} }, 2, 'and the rows' );
    is_deeply( [ sort @{ $idx->{extensions}{probe}{functions} } ], [ "${M}::Actions::echo", "${M}::Actions::who" ],
        'the handlers are the hook functions' );

    my %core = map { $_ => 1 } Lazysite::Auth::Settings::core_capability_keys();
    ok( !$core{probe_things}, 'the core literal does not carry it' );
    ok( !( grep { $_ eq 'probe_things' } @Lazysite::Auth::Settings::CAP_KEYS ), 'nor @CAP_KEYS before the mirror' );
    ok( !exists $Lazysite::ControlApi::Actions::ACTION{'probe-echo'}, 'nor the action table' );

    ok( mirror("$d/lazysite"), 'the mirror reads the index' );
    ok( ( grep { $_ eq 'probe_things' } @Lazysite::Auth::Settings::CAP_KEYS ), '@CAP_KEYS has the capability' );
    is( Lazysite::Auth::Settings::capability_declared_by('probe_things'), 'probe', 'and knows whose it is' );
    my $map = Lazysite::Capabilities::describe()->{capabilities}{probe_things};
    is( $map->{extension}, 'probe',        'the capability map says whose it is' );
    is( $map->{label},     'Probe things', 'with the grid label' );
    is_deeply( $map->{unlocks}, { api => ['probe-echo'], mcp => ['probe_echo'], ui => ['the probe panel'] },
        'its api and mcp unlocks are derived from the gate rows that name it' );
    is_deeply( [ Lazysite::Capabilities::top_up_from('probe_things') ], ['manage_connectors'], 'and what tops it up' );
    is_deeply( $Lazysite::ControlApi::Actions::GATE{'probe-echo'}, ['probe_things'], 'the gate row' );
    is( $Lazysite::ControlApi::Actions::GATE{'probe-who'}, 'ALWAYS', 'and the ALWAYS row' );
    my $spec = $Lazysite::ControlApi::Actions::ACTION{'probe-echo'};
    is( $spec->{extension}, 'probe',               'the action row is marked' );
    is( $spec->{handler},   "${M}::Actions::echo", 'with its handler' );
    is_deeply( $spec->{caps}, ['probe_things'], 'caps derived as a core row\'s are' );
    my %mut = Lazysite::ControlApi::Actions::mutating();
    ok( $mut{'probe-echo'} && !$mut{'probe-who'}, 'the derived tables carry the row' );
    my %twins = Lazysite::ControlApi::Actions::mcp_twins();
    is( $twins{'probe-echo'}, 'probe_echo', 'and the twin' );
    my %ann = Lazysite::ControlApi::Actions::mcp_annotations();
    is_deeply( $ann{probe_echo}, [ 0, 0, 0, 0 ], 'with its hints derived' );
    my %tools = Lazysite::ControlApi::Actions::declared_tools();
    is( $tools{probe_echo}{cap}, 'probe_things', 'the tool row carries the gate' );
    is( $tools{probe_who}{cap},  undef,          'and an ALWAYS row is channel-only' );
    is( Lazysite::Manager::Common::refusal_status('probe-tired'), '429 Too Many Requests', 'the refusal kind maps' );

    ok( !mirror("$d/lazysite"), 'a second read of the same index changes nothing' );
    unmirror();
    ok( !( grep { $_ eq 'probe_things' } @Lazysite::Auth::Settings::CAP_KEYS ), 'unmirrored, the literal is back' );
    ok( !exists $Lazysite::ControlApi::Actions::ACTION{'probe-echo'}, 'and the row is gone' );
};

subtest 'both doors dispatch the declared action to the handler' => sub {
    my ( $base, $d ) = fixture();
    ok( action_extension_enable('extensions/probe.pl')->{ok}, 'enabled' );
    accounts($d);

    my $r = api( $d, 'op', 'probe-echo', { word => 'hello' }, 'action=probe-echo&times=3' );
    ok( $r->{ok}, 'the control API ran it' ) or diag explain $r;
    is( $r->{word},    'hello', 'with the body parameter' );
    is( $r->{times},   '3',     'and the query parameter, each from where the row says' );
    is( $r->{user},    'op',    'as the verified account' );
    is( $r->{channel}, 'api',   'on this door' );
    is( $r->{docroot}, $d,      'told where the site is' );
    is( $r->{action},    'probe-echo', 'and which action' );
    is( $r->{extension}, 'probe',      'of which extension' );
    is( $r->{has_cap},   1,            'with the caller\'s capabilities' );

    $r = api( $d, 'tk', 'probe-echo', { word => 'x' } );
    is( $r->{_status}, 403, 'a caller without the capability is refused at the gate' );
    like( $r->{error}, qr/needs probe_things/, 'naming it' );
    $r = api( $d, 'op', 'probe-echo', {} );
    is( $r->{_status}, 400, 'a missing required parameter is refused before the handler' );
    like( $r->{error}, qr/word/, 'naming it' );
    $r = api( $d, 'op', 'probe-echo', { word => 'x' }, 'action=probe-echo' );
    $r = api( $d, 'tk', 'probe-who' );
    ok( $r->{ok} && $r->{user} eq 'tk', 'the ALWAYS row runs for any authenticated caller' );
    $r = api( $d, 'tk', 'probe-who', {}, 'action=probe-who' );

    my $list = mcp( $d, 'op', 'tools/list' );
    my %tool = map { $_->{name} => $_ } @{ $list->{result}{tools} || [] };
    ok( $tool{probe_echo}, 'tools/list offers the twin' ) or diag explain [ map { $_->{name} } @{ $list->{result}{tools} || [] } ];
    is( $tool{probe_echo}{description}, 'Echo a word.', 'with the declared description' );
    is_deeply( $tool{probe_echo}{inputSchema}{required}, ['word'], 'and schema' );
    ok( !$tool{probe_echo}{annotations}{readOnlyHint}, 'and the hints derived from the row' );
    $list = mcp( $d, 'tk', 'tools/list' );
    my @names = map { $_->{name} } @{ $list->{result}{tools} || [] };
    ok( !( grep { $_ eq 'probe_echo' } @names ), 'a caller without the capability is not offered it' );
    ok( ( grep { $_ eq 'probe_who' } @names ), 'but is offered the ALWAYS twin' );

    my $t = tool_result( mcp( $d, 'op', 'tools/call', { name => 'probe_echo', arguments => { word => 'hi', times => 2 } } ) );
    ok( $t->{ok}, 'MCP ran it' ) or diag explain $t;
    is( $t->{word},    'hi',  'with the arguments by the row\'s names' );
    is( $t->{times},   2,     'all of them' );
    is( $t->{channel}, 'mcp', 'on this door' );
    is( $t->{user},    'op',  'as the account' );
    my $no = mcp( $d, 'tk', 'tools/call', { name => 'probe_echo', arguments => { word => 'hi' } } );
    ok( $no->{error}, 'a caller without the capability is refused' );
    like( $no->{error}{message}, qr/probe_things/, 'naming it' );
    $t = tool_result( mcp( $d, 'tk', 'tools/call', { name => 'probe_who', arguments => {} } ) );
    is( $t->{user}, 'tk', 'the ALWAYS twin runs for any authenticated caller' );

    my $who = tool_result( mcp( $d, 'op', 'tools/call', { name => 'whoami', arguments => {} } ) );
    ok( $who->{capabilities}{probe_things}, 'whoami reports the declared capability as held' ) or diag explain $who->{capabilities};
    my $dc = tool_result( mcp( $d, 'op', 'tools/call', { name => 'describe_capabilities', arguments => {} } ) );
    is( $dc->{capabilities}{probe_things}{extension}, 'probe', 'describe_capabilities says whose it is' );
};

subtest 'the extension off while the index lists it: both doors answer "off", running nothing' => sub {
    my ( $base, $d ) = fixture();
    ok( action_extension_enable('extensions/probe.pl')->{ok}, 'enabled' );
    accounts($d);
    # The conf loses the entry; the index does not hear of it (a rebuild that failed).
    spit( "$d/lazysite/lazysite.conf", "site_name: T\ncontrol_api_enabled: true\nmcp_enabled: true\n" );
    ok( !extension_enabled('extensions/probe.pl'), 'off' );
    my $r = api( $d, 'op', 'probe-echo', { word => 'x' } );
    ok( !$r->{ok}, 'the control API refuses' );
    is( $r->{kind}, 'disabled', 'as disabled' );
    like( $r->{error}, qr/This extension \(Probe\) is off/, 'saying so' );
    my $t = tool_result( mcp( $d, 'op', 'tools/call', { name => 'probe_echo', arguments => { word => 'x' } } ) );
    ok( !$t->{ok} && $t->{kind} eq 'disabled', 'and so does MCP' ) or diag explain $t;
    like( $t->{error}, qr/is off/, 'in the same words' );

    # In process too, with the index read as a door reads it.
    mirror("$d/lazysite");
    my $in = run_action( $d, 'probe-echo', { word => 'x' }, { user => 'op', channel => 'test' } );
    is( $in->{kind}, 'disabled', 'run_action refuses' );
    unmirror();
};

subtest 'on, but its hooks not indexed: "cannot run now", naming the rebuild' => sub {
    my ( $base, $d ) = fixture();
    ok( action_extension_enable('extensions/probe.pl')->{ok}, 'enabled' );
    accounts($d);
    my $idx = decode_json( slurp( index_file($d) ) );
    delete $idx->{extensions}{probe};
    spit( index_file($d) . '.new', JSON::PP->new->encode($idx) );
    rename index_file($d) . '.new', index_file($d) or die $!;
    my $r = api( $d, 'op', 'probe-echo', { word => 'x' } );
    is( $r->{kind}, 'cannot-tell', 'refused as cannot-tell' );
    like( $r->{error}, qr/rebuilds its index/, 'naming the remedy' );
};

subtest 'a declaration the build refuses is not enabled, each fault by name' => sub {
    my ( $base, $d ) = fixture();
    my $row_ok = declaration()->{owns}{hooks}{api_actions}[0];
    my @cases  = (
        [ 'a row with no gate', { api_actions => [ { %$row_ok, gate => undef } ] }, qr/has no gate row/ ],
        [ 'a row gated ALWAYS without a reason', { api_actions => [ { %$row_ok, gate => 'ALWAYS' } ] }, qr/gives no always_reason/ ],
        [ 'a name that is not the extension\'s', { api_actions => [ { %$row_ok, name => 'echo-probe' } ] }, qr/starts with the extension's id/ ],
        [ 'a twin that is not the extension\'s', { api_actions => [ { %$row_ok, mcp => 'echo_probe' } ] }, qr/starts with the extension's id/ ],
        [ 'a name that is not the extension\'s, spelled as a core one', { api_actions => [ { %$row_ok, name => 'whoami' } ] }, qr/starts with the extension's id/ ],
        [ 'a core capability as its own', { capabilities => ['manage_content'], capability_info => { manage_content => declaration()->{owns}{hooks}{capability_info}{probe_things} }, api_actions => [ { %$row_ok, gate => ['manage_content'], cookie_cap => 'manage_content' } ] }, qr/is a core capability/ ],
        [ 'an owned capability nobody describes', { capability_info => {} }, qr/owned and not described/ ],
        [ 'a description of a capability it does not own', { capabilities => [] }, qr/described and not in owns.capabilities/ ],
        [ 'a gate naming no capability of anyone\'s', { api_actions => [ { %$row_ok, gate => ['probe_other'], cookie_cap => 'probe_other' } ] }, qr/no capability of core's or this extension's/ ],
        [ 'a twin requiring what the action does not', { api_actions => [ { %$row_ok, params => [ { name => 'word', in => 'body' }, { name => 'times', in => 'query' } ] } ] }, qr/twin requires 'word' and the action does not/ ],
        [ 'a cookie gate weaker than the token gate', { api_actions => [ { %$row_ok, cookie_cap => 'manage_content' } ] }, qr/cookie_cap names the same capabilities as the gate/ ],
        [ 'a handler the payload does not have', { api_actions => [ { %$row_ok, handler => 'Probe::Absent::f' } ] }, qr/not a file in the extension's payload lib/ ],
    );
    for my $c (@cases) {
        my ( $what, $over, $why ) = @$c;
        write_extension( "$base/extensions/probe.pl", declaration(%$over) );
        my $r = action_extension_enable('extensions/probe.pl');
        ok( !$r->{ok}, "$what: refused" ) or diag explain $r;
        like( $r->{error}, $why, "$what: saying why" );
        ok( !extension_enabled('extensions/probe.pl'), "$what: and not enabled" );
        ok( !-e index_file($d),                        "$what: nothing indexed" );
    }
    write_extension( "$base/extensions/probe.pl", declaration() );
    ok( action_extension_enable('extensions/probe.pl')->{ok}, 'the sound declaration enables' );

    # The second wall, where the prefix rule does not stand in front of it: an
    # extension whose id is a core action's own prefix (data) declaring that
    # core action (data-tables) as its own is refused as a shadow, and so is a
    # core tool (list_data_tables is core's twin of data-tables).
    my @why = map { $_->{error} } Lazysite::Extensions::Declared::check_declared( 'data',
        { capabilities => [], hooks => { api_actions => [ { %$row_ok, name => 'data-tables', mcp => 'data_tables', gate => 'ALWAYS', always_reason => 'x' x 50, handler => 'Data::X::f', params => [], input_schema => { type => 'object', properties => {}, additionalProperties => $F }, description => 'x' } ] } } );
    ok( ( grep { /'data-tables' is a core action/ } @why ), 'a core action spelled with the extension\'s own prefix is refused as a shadow' )
        or diag explain \@why;
    my @t = map { $_->{error} } Lazysite::Extensions::Declared::check_declared( 'list',
        { capabilities => [], hooks => { api_actions => [ { %$row_ok, name => 'list-x', mcp => 'list_data_tables', gate => 'ALWAYS', always_reason => 'x' x 50, handler => 'List::X::f', params => [], input_schema => { type => 'object', properties => {}, additionalProperties => $F }, description => 'x' } ] } } );
    ok( ( grep { /'list_data_tables' is a core tool/ } @t ), 'and a core tool' ) or diag explain \@t;
    my @c = map { $_->{error} } Lazysite::Extensions::Declared::check_declared( 'x',
        { capabilities => [], hooks => { refusal_kinds => { 'not-found' => '404 Not Found' } } } );
    ok( ( grep { /'not-found' is a core refusal kind/ } @c ), 'and a core refusal kind' ) or diag explain \@c;
};

subtest 'disabled, the declaration stays indexed (off) and the hooks leave' => sub {
    my ( $base, $d ) = fixture();
    action_extension_enable('extensions/probe.pl');
    accounts($d);
    my $r = action_extension_disable('extensions/probe.pl');
    ok( $r->{ok}, 'disabled' );
    is_deeply( $r->{index}{indexed}, [], 'no hooks indexed' );
    is_deeply( $r->{index}{declared}, ['probe'], 'the declaration stays, so the action is known and answers off' );
    my $api = api( $d, 'op', 'probe-echo', { word => 'x' } );
    is( $api->{kind}, 'disabled', 'the control API says off' );
    my $list = mcp( $d, 'op', 'tools/list' );
    ok( ( grep { $_->{name} eq 'probe_echo' } @{ $list->{result}{tools} || [] } ), 'the listing is unchanged by the toggle' );
};

done_testing();
