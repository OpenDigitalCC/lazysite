#!/usr/bin/perl
# SM1325 (ruling 50, T-17): A SUCCESSFUL AI READ IS AUDITED WHEN THE SITE ASKS.
#
# SM943 ruling 1 kept successful reads out of the audit trail: site activity,
# noise. Ruling 50 makes it a per-site choice. `audit_reads: on` in
# lazysite.conf records each successful MCP or control-API read of a page or a
# file - the actor, the path and the time - in the existing trail. Off by
# default, and absence is off.
#
# Driven through the real dispatchers, both doors:
#   - off: a successful read writes no row (SM943 unchanged);
#   - on: read_file, read_page, view_version and preview_page each write one
#     `ok` row naming the account and the path, as do the control API's git-show
#     for a token (its other content read, file-download, is audited always);
#   - on: a read that is not of a page or a file (describe_capabilities,
#     list_files) still writes none, and neither does a signed-in person's read
#     on the manager (the ruling is about AI reads);
#   - a value other than on is off.
use strict;
use warnings;
use Test::More;
use File::Path   qw(make_path);
use JSON::PP     qw(encode_json decode_json);
use MIME::Base64 qw(encode_base64);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper qw(grant_caps repo_root site_tempdir run_child);
use Lazysite::Git ();

my $root = repo_root();
my $mcp  = "$root/lazysite-mcp.pl";
my $mapi = "$root/lazysite-manager-api.pl";
my $tool = "$root/tools/lazysite-users.pl";
plan skip_all => 'no engine scripts' unless -f $mcp && -f $mapi && -f $tool;
plan skip_all => 'git not installed on this host' unless Lazysite::Git::git_available();

my $d = site_tempdir();
make_path( "$d/lazysite/manager/locks", "$d/lazysite/auth", "$d/lazysite/logs" );
open my $pg, '>', "$d/here.md" or die $!;
print {$pg} "---\ntitle: Here\n---\nbody\n";
close $pg;

sub conf {
    my ($extra) = @_;
    open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
    print {$cf} "layout: base\ntheme: sky\nmcp_enabled: true\ncontrol_api_enabled: true\n"
        . "git_history: enabled\n" . ( $extra // '' );
    close $cf;
    return;
}
conf();
Lazysite::Git::init( $d, 'local' )->{ok} or BAIL_OUT('git init failed');

# MCP: a stub users-tool grants 'agent' content reads.
my $stub = "$d/users-stub.pl";
open my $sf, '>', $stub or die $!;
print {$sf} <<'STUB';
#!/usr/bin/perl
use strict; use warnings; use JSON::PP qw(encode_json decode_json);
my $in = do { local $/; <STDIN> };
print encode_json({ ok => 1, settings => { mcp => 1, manage_content => 1 } });
STUB
close $sf;
chmod 0755, $stub;

sub call {
    my ( $name, $args ) = @_;
    my $body = encode_json( { jsonrpc => '2.0', id => 1, method => 'tools/call',
            params => { name => $name, arguments => $args || {} } } );
    local %ENV = %ENV;
    $ENV{DOCUMENT_ROOT}       = $d;
    $ENV{REQUEST_METHOD}      = 'POST';
    $ENV{CONTENT_LENGTH}      = length $body;
    $ENV{LAZYSITE_USERS_TOOL} = $stub;
    $ENV{HTTP_AUTHORIZATION}  = 'Bearer agent:lzs_x';
    my $resp = run_child( [ $^X, $mcp ], stdin => $body, stderr => 'inherit' )->{out};
    my ($jb) = $resp =~ /\r?\n\r?\n(.*)/s;
    return ( defined $jb && length $jb ) ? eval { decode_json($jb) } : undef;
}

# The control API: a real account and token.
sub uapi {
    my ($p) = @_;
    my $out = run_child( [ $^X, $tool, '--api', '--docroot', $d ],
        stdin => encode_json($p), stderr => 'inherit' )->{out};
    return eval { decode_json($out) } // {};
}
uapi( { action => 'add', username => 'rd', password => 'x-long-enough' } );
grant_caps( $d, 'rd', qw(api manage_content) );
my $tok = uapi( { action => 'token', username => 'rd' } )->{token};

sub api {
    my ( $query, %o ) = @_;
    local %ENV = %ENV;
    delete @ENV{qw(HTTP_X_REMOTE_USER HTTP_X_REMOTE_GROUPS LAZYSITE_AUTH_TRUSTED HTTP_COOKIE HTTP_AUTHORIZATION)};
    $ENV{DOCUMENT_ROOT}  = $d;
    $ENV{REQUEST_METHOD} = $o{body} ? 'POST' : 'GET';
    $ENV{QUERY_STRING}   = $query;
    $ENV{CONTENT_LENGTH} = $o{body} ? length $o{body} : 0;
    $ENV{CONTENT_TYPE}   = 'application/json' if $o{body};
    if ( $o{cookie_user} ) {
        $ENV{HTTP_X_REMOTE_USER}    = $o{cookie_user};
        $ENV{LAZYSITE_AUTH_TRUSTED} = 1;
    }
    else {
        my ( $u, $k ) = $o{as} ? @{ $o{as} } : ( 'rd', $tok );
        $ENV{HTTP_AUTHORIZATION} = 'Basic ' . encode_base64( "$u:$k", '' );
    }
    my $out = run_child( [ $^X, $mapi ], stdin => ( $o{body} // '' ) )->{out};
    my ($jb) = $out =~ /\r?\n\r?\n(.*)/s;
    return eval { decode_json( $jb // '' ) } // { _raw => $out };
}

# Ruling 97: the reads have a file of their own; the change trail never sees them.
my $log     = "$d/lazysite/logs/audit-reads.log";
my $changes = "$d/lazysite/logs/audit.log";
sub rows_since {
    my ( $from, $file ) = @_;
    open my $fh, '<', ( $file // $log ) or return ();
    my @l = <$fh>;
    close $fh;
    return @l[ $from .. $#l ];
}
sub mark { my @all = rows_since( 0, $_[0] ); return scalar @all }

# A version to view: content history on, and one save through MCP.
ok( $tok, 'a token for the control API' ) or BAIL_OUT('no token');
{
    my $w = call( 'write_file', { path => '/hist.md', content => "---\ntitle: H\n---\nv1\n" } );
    ok( $w && $w->{result} && !$w->{result}{isError}, 'a page to version' ) or diag encode_json($w);
}

sub hist_sha {
    my $v = call( 'list_versions', { path => '/hist.md' } );
    return $v && $v->{result} ? ( $v->{result}{structuredContent}{versions} || [] )->[0]{sha} : undef;
}

sub mcp_reads {
    my $v = call( 'list_versions', { path => '/hist.md' } );
    my $sha = $v && $v->{result} ? ( $v->{result}{structuredContent}{versions} || [] )->[0]{sha} : undef;
    return (
        [ read_file    => { path => '/here.md' } ],
        [ read_page    => { path => '/here.md' } ],
        [ preview_page => { path => '/here.md' } ],
        ( $sha ? [ view_version => { path => '/hist.md', version => $sha } ] : () ),
    );
}

subtest 'off by default: a successful read writes no row' => sub {
    conf();
    for my $c ( mcp_reads() ) {
        my ( $name, $args ) = @$c;
        my $m = mark();
        my $r = call( $name, $args );
        ok( $r && $r->{result} && !$r->{result}{isError}, "$name succeeds" ) or diag encode_json($r);
        is( scalar( grep { /\| \Q$name\E \|/ } rows_since($m) ), 0, "$name writes no row" );
    }
    my $m = mark();
    my $ar = api( 'action=git-show&path=/hist.md&sha=' . ( hist_sha() // '' ) );
    ok( $ar->{ok}, 'the API read succeeds' ) or diag encode_json($ar);
    is( scalar( grep { /\| git-show \|/ } rows_since($m) ), 0, 'and writes no row' );
};

subtest 'on: each AI read of a page or a file is one row' => sub {
    conf("audit_reads: on\n");
    my $cm    = mark($changes);
    my @reads = mcp_reads();
    is( scalar @reads, 4, 'four MCP content reads, view_version among them' );
    for my $c (@reads) {
        my ( $name, $args ) = @$c;
        my $m = mark();
        my $r = call( $name, $args );
        ok( $r && $r->{result} && !$r->{result}{isError}, "$name succeeds" ) or diag encode_json($r);
        my @new = grep { /\| \Q$name\E \|/ } rows_since($m);
        is( scalar @new, 1, "$name writes one row" ) or diag @new;
        like( $new[0] // '', qr/\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ \| agent \| \Q$name\E \| \Q$args->{path}\E \| .* \| ok \| mcp/,
            '...with the time, the account, the path, ok and the origin' );
    }
    my $m = mark();
    my $ar = api( 'action=git-show&path=/hist.md&sha=' . ( hist_sha() // '' ) );
    ok( $ar->{ok}, 'the API read succeeds' ) or diag encode_json($ar);
    my @new = grep { /\| git-show \|/ } rows_since($m);
    is( scalar @new, 1, 'and writes one row' ) or diag @new;
    like( $new[0] // '', qr/\| rd \| git-show \| \/hist\.md \| .* \| ok \| api/, '...naming the token account' );
    is( scalar( grep { /\| (?:read_file|read_page|view_version|preview_page|git-show) \|/ } rows_since( $cm, $changes ) ),
        0, 'and none of them is on the change trail' );
};

subtest 'on: reads that are not of a page or file, and a person, write none' => sub {
    conf("audit_reads: on\n");
    for my $c ( [ describe_capabilities => {} ], [ list_files => { path => '/' } ] ) {
        my ( $name, $args ) = @$c;
        my $m = mark();
        call( $name, $args );
        is( scalar( grep { /\| \Q$name\E \|/ } rows_since($m) ), 0, "$name writes no row" );
    }
    my $m = mark();
    my $pr = api( 'action=git-show&path=/hist.md&sha=' . ( hist_sha() // '' ), cookie_user => 'local' );
    ok( $pr->{ok}, 'a signed-in person reads the version' ) or diag encode_json($pr);
    is( scalar( grep { /\| git-show \|/ } rows_since($m) ), 0, 'a signed-in person\'s read writes none' );
};

subtest 'a value other than on is off' => sub {
    conf("audit_reads: maybe\n");
    my $m = mark();
    call( 'read_file', { path => '/here.md' } );
    is( scalar( grep { /\| read_file \|/ } rows_since($m) ), 0, 'no row' );
};

# Ruling 96: the manager switches it, with the trail's own gate - Site config
# AND the audit trail switch permission.
subtest 'config-set switches it, gated by manage_config AND audit_switch' => sub {
    conf();
    uapi( { action => 'add', username => $_, password => 'x-long-enough' } ) for qw(cfg sw);
    grant_caps( $d, 'cfg', qw(api manage_config) );
    grant_caps( $d, 'sw',  qw(api manage_config audit_switch audit) );
    my $ct = uapi( { action => 'token', username => 'cfg' } )->{token};
    my $st = uapi( { action => 'token', username => 'sw' } )->{token};
    my $body = encode_json( { key => 'audit_reads', value => 'on' } );
    my $no = api( 'action=config-set', as => [ 'cfg', $ct ], body => $body );
    ok( !$no->{ok}, 'manage_config alone is refused' ) or diag encode_json($no);
    like( $no->{error} // '', qr/audit trail switch/, '...naming the permission it lacks' );
    unlike( do { open my $c, '<', "$d/lazysite/lazysite.conf"; local $/; <$c> }, qr/^audit_reads/m,
        '...and nothing is written' );
    my $yes = api( 'action=config-set', as => [ 'sw', $st ], body => $body );
    ok( $yes->{ok}, 'manage_config with audit_switch switches it on' ) or diag encode_json($yes);
    my $r = call( 'read_file', { path => '/here.md' } );
    ok( $r && !$r->{result}{isError}, 'a read' );
    my $bad = api( 'action=config-set', as => [ 'sw', $st ],
        body => encode_json( { key => 'audit_reads', value => 'maybe' } ) );
    ok( !$bad->{ok}, 'a value other than on, off or empty is refused' );

    # Ruling 97: the Audit page's reads view reads that file; the change view does not.
    my $reads = api( 'action=audit&view=reads', as => [ 'sw', $st ] );
    ok( $reads->{ok} && $reads->{view} eq 'reads', 'the reads view answers' ) or diag encode_json($reads);
    ok( ( grep { ($_->{action} // '') eq 'read_file' } @{ $reads->{entries} || [] } ), '...with the read' );
    my $chg = api( 'action=audit', as => [ 'sw', $st ] );
    ok( $chg->{ok} && $chg->{view} eq 'changes', 'the change view answers' );
    ok( !( grep { ($_->{action} // '') eq 'read_file' && ($_->{status} // '') eq 'ok' } @{ $chg->{entries} || [] } ),
        '...without it' );
    ok( ( grep { ($_->{action} // '') eq 'config-set' } @{ $chg->{entries} || [] } ),
        '...and with the switch itself, which is a change' );
};

# The reads file is a store the web server appends to: the installer and
# `lazysite check` keep it group-writable (the model they share, which
# t/lint/30 holds check 4b to), and the Audit page says when it is not.
subtest 'the reads file is kept writable, and its health is reported' => sub {
    my $model = do {
        open my $m, '<', "$root/dist/config/classification.json" or die $!;
        local $/;
        decode_json(<$m>);
    };
    ok( ( grep { ( $_->{path} // '' ) eq '{LAZYSITE}/logs/audit-reads.log' && ( $_->{ensure} // '' ) eq 'group-write' }
                @{ $model->{runtime_files} || [] } ),
        'the permission model declares it group-writable' );

    uapi( { action => 'add', username => 'hv', password => 'x-long-enough' } );
    grant_caps( $d, 'hv', qw(api audit) );
    my $ht = uapi( { action => 'token', username => 'hv' } )->{token};

    conf();
    my $off = api( 'action=audit&view=reads', as => [ 'hv', $ht ] );
    is( $off->{trail}{state}, 'reads-off', 'off: the reads view says reads are not being recorded' )
        or diag encode_json( $off->{trail} );

    conf("audit_reads: on\n");
    call( 'read_file', { path => '/here.md' } );
    my $on = api( 'action=audit&view=reads', as => [ 'hv', $ht ] );
    is( $on->{trail}{state}, 'appendable', 'on: the reads file is appendable' );
    like( $on->{trail}{file} // '', qr{/audit-reads\.log\z}, '...and it is the reads file that was asked' );

  SKIP: {
        skip 'root can write a read-only file', 2 if $> == 0;
        chmod 0444, $log or die $!;
        my $bad = api( 'action=audit&view=reads', as => [ 'hv', $ht ] );
        chmod 0664, $log;
        is( $bad->{trail}{state}, 'unwritable', 'a reads file the server cannot append to is reported' );
        is( api( 'action=audit', as => [ 'hv', $ht ] )->{trail}{state}, 'appendable',
            '...while the change view reports its own file' );
    }
};

done_testing();
