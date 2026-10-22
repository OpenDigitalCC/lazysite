#!/usr/bin/perl
# SM1144 (SM1082 T0): EVERY SURFACE SAYS WHERE ITS TIME WENT.
#
# SM1082 needs before-figures for the processor, the manager API, MCP, the data
# endpoint, the Odoo endpoint, WebDAV and the auth wrapper before any of the
# persistent-runtime work is built. Each answers with a Server-Timing header
# naming the phases that happened (config, identity, load, render, call, write),
# shown to a verified operator or when lazysite.conf says `server_timing: on`
# and to nobody else.
#
# Each surface is run as the CGI it is, a process per request, and its response
# headers read. The assertion is on the NAMES of the phases and on the switch,
# never on a duration: a number measured on a shared host asserts nothing a
# machine can repeat.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use JSON::PP qw(encode_json decode_json);
use Digest::SHA qw(hmac_sha256_hex);
use MIME::Base64 ();
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root site_tempdir setup_auth_site run_dav setup_dav_site dav_users_tool run_child);
use ManagerSession qw(new_site);

my $root = repo_root();

# One request through a script as a CGI. Returns { status, head (lowercase-keyed
# hash), raw_head, body }.
sub cgi {
    my ( $script, $env, $stdin ) = @_;
    $stdin //= '';
    local %ENV = ( PATH => $ENV{PATH}, TestHelper::env_passthrough(), %{$env} );
    my ( $o, $e ) = @{ run_child( [ $^X, "$root/$script" ], stdin => $stdin ) }{qw(out err)};
    my ( $head, $body ) = split /\r?\n\r?\n/, $o, 2;
    my %h;
    for my $l ( split /\r?\n/, $head // '' ) {
        $h{ lc $1 } = $2 if $l =~ /\A([^:]+):\s*(.*)\z/;
    }
    my ($st) = ( $head // '' ) =~ /^Status:\s*(\d+)/m;
    return { status => $st // 200, head => \%h, raw_head => $head // '', body => $body // '', err => $e };
}

# The phase names a response's Server-Timing header carries, or undef.
sub phases_of {
    my ($r) = @_;
    my $v = $r->{head}{'server-timing'};
    return undef unless defined $v;
    my @n;
    for my $m ( split /,\s*/, $v ) {
        return undef unless $m =~ /\A([a-z]+);dur=\d+(?:\.\d+)?\z/;
        push @n, $1;
    }
    return \@n;
}

my @KNOWN = qw(config identity load render call write);

sub has {
    my ( $got, @want ) = @_;
    return 0 unless $got;
    my %g = map { $_ => 1 } @$got;
    return !grep { !$g{$_} } @want;
}

sub only_known {
    my ($got) = @_;
    my %k = map { $_ => 1 } @KNOWN;
    return !grep { !$k{$_} } @$got;
}

sub set_conf {
    my ( $d, $extra ) = @_;
    open my $fh, '>>', "$d/lazysite/lazysite.conf" or die $!;
    print {$fh} $extra;
    close $fh;
    # the helper memoises the conf on (mtime, size); a longer file always differs
    return;
}

# --- the processor ---------------------------------------------------------------
subtest 'the processor' => sub {
    my $d = site_tempdir();
    setup_auth_site($d);
    my %env = ( DOCUMENT_ROOT => $d, REDIRECT_URL => '/', REQUEST_METHOD => 'GET', QUERY_STRING => '',
        REMOTE_ADDR => '127.0.0.1' );

    my $r = cgi( 'lazysite-processor.pl', \%env );
    is( $r->{status}, 200, 'an anonymous page is served' );
    ok( !exists $r->{head}{'server-timing'}, '...with no Server-Timing header by default' );

    $r = cgi( 'lazysite-processor.pl',
        { %env, HTTP_X_REMOTE_USER => 'alice', HTTP_X_REMOTE_GROUPS => 'admins' } );
    my $p = phases_of($r);
    ok( $p && has( $p, qw(config render) ), 'a signed-in operator is shown the phases' )
        or diag( $r->{raw_head} );
    ok( $p && only_known($p), '...and only phases from the closed list' );

    set_conf( $d, "server_timing: on\n" );
    cgi( 'lazysite-processor.pl', \%env );    # the conf changed, so this one re-renders; the next is a hit
    $r = cgi( 'lazysite-processor.pl', \%env );
    $p = phases_of($r);
    ok( $p && has( $p, qw(config load render) ), 'server_timing: on shows an anonymous visitor the phases' )
        or diag( $r->{raw_head} );
    ok( $p && !has( $p, 'write' ), 'a cache hit writes nothing, so has no write phase' );

    # A page nobody has rendered: the render writes its cache.
    open my $pf, '>', "$d/fresh.md" or die $!;
    print {$pf} "---\ntitle: Fresh\n---\nFresh page.\n";
    close $pf;
    $r = cgi( 'lazysite-processor.pl', { %env, REDIRECT_URL => '/fresh' } );
    $p = phases_of($r);
    ok( $p && has( $p, qw(render write) ), 'a render that writes its cache has a write phase' )
        or diag( $r->{raw_head} );

    $r = cgi( 'lazysite-processor.pl', { %env, REDIRECT_URL => '/no-such-page' } );
    is( $r->{status}, 404, 'a missing page' );
    ok( phases_of($r), '...answers with the header too' );

    # The access log line gains the same phases and keeps what it had.
    my @logs = glob("$d/lazysite/logs/access-*.jsonl");
    ok( scalar @logs, 'the access log was written' );
    my @lines = do { open my $lf, '<', $logs[0] or die $!; <$lf> };
    my $last = decode_json( $lines[-1] );
    ok( ref $last->{tm} eq 'HASH' && exists $last->{tm}{config}, 'the last line carries a tm object with the phases' )
        or diag( $lines[-1] );
    ok( exists $last->{$_}, "...and still has its '$_' field" ) for qw(t p s ch v ua);
};

# --- the auth wrapper's hand-over ------------------------------------------------
subtest 'the auth wrapper hands its time to the surface it execs' => sub {
    my $d = site_tempdir();
    setup_auth_site($d);
    set_conf( $d, "server_timing: on\n" );
    my $r = cgi( 'lazysite-auth.pl',
        { DOCUMENT_ROOT => $d, REDIRECT_URL => '/', REQUEST_METHOD => 'GET', QUERY_STRING => '',
            REMOTE_ADDR => '127.0.0.1', LAZYSITE_PROCESSOR => "$root/lazysite-processor.pl" } );
    my $p = phases_of($r);
    ok( $p && has( $p, qw(identity render) ), 'the processor behind the wrapper reports an identity phase' )
        or diag( $r->{raw_head} . "\n" . $r->{err} );

    # What the wrapper hands across, read from a stand-in surface that prints it:
    # the figure comes from the wrapper, whatever the processor measures itself.
    my $stub = "$d/stub-surface.pl";
    open my $sf, '>', $stub or die $!;
    print {$sf} "print qq(Content-Type: text/plain\\r\\n\\r\\n); print \$ENV{LAZYSITE_TIMING_HANDOVER} // 'none';\n";
    close $sf;
    $r = cgi( 'lazysite-auth.pl',
        { DOCUMENT_ROOT => $d, REDIRECT_URL => '/', REQUEST_METHOD => 'GET', QUERY_STRING => '',
            REMOTE_ADDR => '127.0.0.1', LAZYSITE_PROCESSOR => $stub } );
    like( $r->{body}, qr/\Aidentity=\d+\.\d+(?:;load=\d+\.\d+)?\z|\Aload=\d+\.\d+;identity=\d+\.\d+\z/,
        'the wrapper hands over its time as identity, and its module loading as load' )
        or diag($r->{body});
};

# --- the manager API -------------------------------------------------------------
my $s = new_site( root => $root, conf => "control_api_enabled: true\nmanager: enabled\n" );
$s->add_user('op');
$s->grant( 'op', 'g-op', [ 'ui', 'manage_users' ], [ 'ui', 'manage_users' ] );
subtest 'the manager API' => sub {
    my $d = $s->docroot;
    my %env = (
        DOCUMENT_ROOT => $d, REQUEST_METHOD => 'GET', QUERY_STRING => 'action=whoami',
        HTTP_X_REMOTE_USER => 'op', LAZYSITE_AUTH_TRUSTED => '1',
        HTTP_COOKIE => $s->cookie_for('op'), LAZYSITE_USERS_TOOL => "$root/tools/lazysite-users.pl",
    );
    my $r = cgi( 'lazysite-manager-api.pl', \%env );
    my $p = phases_of($r);
    ok( $p && has( $p, qw(config render) ), 'a signed-in operator is shown the phases' )
        or diag( $r->{raw_head} . $r->{body} . $r->{err} );
    ok( $p && only_known($p), '...from the closed list' );

    $r = cgi( 'lazysite-manager-api.pl',
        { DOCUMENT_ROOT => $d, REQUEST_METHOD => 'GET', QUERY_STRING => 'action=whoami' } );
    ok( !exists $r->{head}{'server-timing'}, 'an unauthenticated request is shown nothing' );

    set_conf( $d, "server_timing: on\n" );
    $r = cgi( 'lazysite-manager-api.pl',
        { DOCUMENT_ROOT => $d, REQUEST_METHOD => 'GET', QUERY_STRING => 'action=whoami' } );
    ok( phases_of($r), '...unless the site says server_timing: on' );
};

# --- MCP ------------------------------------------------------------------------
subtest 'MCP' => sub {
    my $m = new_site( root => $root, conf => "mcp_enabled: true\nmanager: enabled\n" );
    my $d = $m->docroot;
    $m->add_user( 'agent', 'pw-agent-0123456789' );
    $m->grant( 'agent', 'g-agent', ['mcp'], ['mcp'] );
    my $got = run_child( [ $^X, "$root/tools/lazysite-users.pl", '--api', '--docroot', $d ],
        stdin => encode_json( { action => 'token', username => 'agent' } ), stderr => 'inherit' )->{out};
    my $tok = eval { decode_json($got)->{token} } // '';
    ok( length $tok, 'a connector token was minted' ) or return;

    my $call = encode_json( { jsonrpc => '2.0', id => 1, method => 'tools/call',
            params => { name => 'whoami', arguments => {} } } );
    my %env = ( DOCUMENT_ROOT => $d, REQUEST_METHOD => 'POST', CONTENT_LENGTH => length $call );
    my $r = cgi( 'lazysite-mcp.pl', { %env, HTTP_AUTHORIZATION => "Bearer agent:$tok" }, $call );
    my $p = phases_of($r);
    ok( $p && has( $p, qw(config render) ), 'an authenticated connector is shown the phases' )
        or diag( $r->{raw_head} . $r->{body} . $r->{err} );

    my $init = encode_json( { jsonrpc => '2.0', id => 1, method => 'initialize', params => {} } );
    $r = cgi( 'lazysite-mcp.pl', { %env, CONTENT_LENGTH => length $init }, $init );
    is( $r->{status}, 200, 'an unauthenticated initialize is answered' );
    ok( !exists $r->{head}{'server-timing'}, '...with nothing shown' );

    $r = cgi( 'lazysite-mcp.pl', { %env, HTTP_AUTHORIZATION => 'Bearer agent:lzs_wrong' }, $call );
    ok( !exists $r->{head}{'server-timing'}, 'a refused credential is shown nothing' );

    set_conf( $d, "server_timing: on\n" );
    $r = cgi( 'lazysite-mcp.pl', { %env, CONTENT_LENGTH => length $init }, $init );
    ok( phases_of($r), 'server_timing: on shows even the anonymous initialize' );
};

# --- the data endpoint -----------------------------------------------------------
SKIP: {
    skip 'DBI/DBD::SQLite/YAML::PP not available', 1
        unless eval { require DBI; require DBD::SQLite; require YAML::PP; 1 };
    subtest 'the data endpoint' => sub {
        require Lazysite::Data::Tables;
        my $d = site_tempdir();
        make_path( "$d/lazysite/db/tables", "$d/lazysite/auth" );
        open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
        print {$cf} "site_name: T\nplugins:\n  - plugins/data.pl\n";
        close $cf;
        open my $df, '>', "$d/lazysite/db/tables/notes.yaml" or die $!;
        print {$df} "public: true\nkey: code\nfields:\n  code:\n    type: text\n    required: true\n";
        close $df;
        Lazysite::Data::Tables::apply_schema( $d, 'notes' );
        open my $kf, '>', "$d/lazysite/auth/.secret" or die $!;
        print {$kf} 'a' x 64;
        close $kf;
        chmod 0600, "$d/lazysite/auth/.secret";
        my $users = "$root/tools/lazysite-users.pl";
        qx($^X \Q$users\E --docroot \Q$d\E setup-sysop --user sjm pw123456789-long-enough 2>/dev/null);
        my $secret = do { open my $sf, '<', "$d/lazysite/auth/.secret" or die "secret: $!"; local $/; <$sf> };
        $secret =~ s/\s+\z//;
        my $payload = 'sjm:' . time . ':';
        my $cookie  = 'lazysite_auth=' . $payload . ':' . hmac_sha256_hex( $payload, $secret );

        my %env = ( DOCUMENT_ROOT => $d, REQUEST_METHOD => 'GET', QUERY_STRING => 'table=notes', REMOTE_ADDR => '203.0.113.5' );
        my $r = cgi( 'lazysite-data.pl', \%env );
        is( $r->{status}, 200, 'an anonymous read of a public table' );
        ok( !exists $r->{head}{'server-timing'}, '...shows nothing by default' );

        $r = cgi( 'lazysite-data.pl', { %env, HTTP_COOKIE => $cookie } );
        my $p = phases_of($r);
        ok( $p && has( $p, qw(config identity render) ), 'a signed-in operator is shown the phases' )
            or diag( $r->{raw_head} . $r->{body} . $r->{err} );

        set_conf( $d, "server_timing: on\n" );
        $r = cgi( 'lazysite-data.pl', \%env );
        ok( phases_of($r), 'server_timing: on shows an anonymous reader' );
    };
}

# --- the Odoo endpoint -----------------------------------------------------------
subtest 'the Odoo endpoint' => sub {
    my $d = site_tempdir( plugins => 1 );
    make_path("$d/lazysite/auth");
    open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
    print {$cf} "site_name: T\nplugins:\n  - plugins/odoo.pl\n";
    close $cf;
    open my $sf, '>', "$d/lazysite/auth/.secret" or die $!;
    print {$sf} 'a' x 64;
    close $sf;
    my %env = ( DOCUMENT_ROOT => $d, REQUEST_METHOD => 'GET', QUERY_STRING => 'csrf=1', REMOTE_ADDR => '203.0.113.5' );
    my $r = cgi( 'lazysite-odoo.pl', \%env );
    is( $r->{status}, 200, 'the tokens are issued' ) or diag( $r->{body} . $r->{err} );
    ok( !exists $r->{head}{'server-timing'}, '...with nothing shown to a visitor by default' );

    set_conf( $d, "server_timing: on\n" );
    $r = cgi( 'lazysite-odoo.pl', \%env );
    my $p = phases_of($r);
    ok( $p && has( $p, qw(config identity load render) ), 'server_timing: on shows the phases, with the load the start-up cost' )
        or diag( $r->{raw_head} . $r->{err} );
};

# --- WebDAV ---------------------------------------------------------------------
subtest 'WebDAV' => sub {
    my $site = setup_dav_site();
    my $d    = $site->{docroot};
    my $r    = run_dav( $d, 'PROPFIND', '/', HTTP_AUTHORIZATION => $site->{auth}, HTTP_DEPTH => '0' );
    my @n    = ( $r->{headers}{'server-timing'} // '' ) =~ /([a-z]+);dur=/g;
    ok( has( \@n, qw(config identity render) ), 'an authenticated operator is shown the phases' )
        or diag( $r->{raw} );

    my $put = run_dav( $d, 'PUT', '/timed.md', HTTP_AUTHORIZATION => $site->{auth}, body => "---\ntitle: T\n---\nBody\n" );
    @n = ( $put->{headers}{'server-timing'} // '' ) =~ /([a-z]+);dur=/g;
    ok( has( \@n, 'write' ), 'a PUT has a write phase' ) or diag( $put->{raw} );

    my $anon = run_dav( $d, 'PROPFIND', '/', HTTP_DEPTH => '0' );
    is( $anon->{code}, 401, 'an unauthenticated request is refused' );
    ok( !exists $anon->{headers}{'server-timing'}, '...and shown nothing' );
};

done_testing;
