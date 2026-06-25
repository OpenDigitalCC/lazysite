#!/usr/bin/perl
# SM076: the remote MCP server - JSON-RPC transport, bearer auth, capability
# gate, and tool dispatch over the shared action handlers. The CGI is run as a
# subprocess; a stub users-tool provides verify-credential so the authenticated
# path is exercised without provisioning real tokens (caps vary by username:
# *full* gets every capability, anyone else gets webdav only).
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP qw(encode_json decode_json);
use IPC::Open2;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);

my $root = repo_root();
my $mcp  = "$root/lazysite-mcp.pl";

my $d = tempdir( CLEANUP => 1 );
make_path( "$d/content", "$d/lazysite/manager/locks", "$d/lazysite/auth" );
open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
print $cf "layout: base\ntheme: sky\n";
close $cf;
open my $pg, '>', "$d/content/page.md" or die $!; print $pg "hello\n"; close $pg;

# Stub users-tool: caps by username.
my $stub = "$d/users-stub.pl";
open my $sf, '>', $stub or die $!;
print $sf <<'STUB';
#!/usr/bin/perl
use strict; use warnings; use JSON::PP qw(encode_json decode_json);
my $in = do { local $/; <STDIN> };
my $r = eval { decode_json($in) } || {};
my $u = $r->{username} // '';
my %caps = $u =~ /full/ ? (webdav=>1, manage_themes=>1, manage_layouts=>1, manage_config=>1)
                        : (webdav=>1);
print encode_json({ ok => 1, settings => \%caps });
STUB
close $sf;
chmod 0755, $stub;

# Run the CGI: returns ($status, $decoded_body_or_undef).
sub mcp {
    my ( $payload, %extra ) = @_;
    my $body = defined $payload ? encode_json($payload) : '';
    local %ENV = %ENV;
    $ENV{DOCUMENT_ROOT}       = $d;
    $ENV{REQUEST_METHOD}      = $extra{method} || 'POST';
    $ENV{CONTENT_LENGTH}      = length $body;
    $ENV{LAZYSITE_USERS_TOOL} = $stub;
    $ENV{HTTP_AUTHORIZATION}  = $extra{auth} if defined $extra{auth};
    my ( $out, $in );
    my $pid = open2( $out, $in, $^X, $mcp );
    print $in $body;
    close $in;
    my $resp = do { local $/; <$out> };
    close $out;
    waitpid $pid, 0;
    my ($status) = $resp =~ /Status:\s*(\d+)/;
    my ($jb)     = $resp =~ /\r?\n\r?\n(.*)/s;
    my $obj = ( defined $jb && length $jb ) ? eval { decode_json($jb) } : undef;
    return ( $status, $obj, $resp );
}

sub call { mcp( { jsonrpc => '2.0', id => 1, method => 'tools/call',
    params => { name => $_[0], arguments => $_[1] || {} } }, auth => $_[2] ) }

my $bearer_full = 'Bearer claudefull:lzs_tok';   # /full/ -> all caps
my $bearer_lim  = 'Bearer claudelim:lzs_tok';    # webdav only

# --- handshake + discovery (no auth) ---
my ( $st, $r ) = mcp( { jsonrpc => '2.0', id => 1, method => 'initialize', params => {} } );
is( $st, 200, 'initialize: 200' );
is( $r->{result}{protocolVersion}, '2025-11-25', 'initialize: protocol version' );
is( $r->{result}{serverInfo}{name}, 'lazysite-mcp', 'initialize: serverInfo' );

( $st, $r ) = mcp( { jsonrpc => '2.0', id => 2, method => 'tools/list' } );
my %names = map { $_->{name} => $_ } @{ $r->{result}{tools} };
ok( $names{whoami} && $names{list_files} && $names{write_file} && $names{activate_theme},
    'tools/list advertises the maintenance tools' );
ok( $names{write_file}{inputSchema}{required}, 'a tool carries a JSON-Schema inputSchema' );
ok( $names{whoami}{annotations}{readOnlyHint}, 'whoami is annotated read-only' );
ok( !$names{write_file}{annotations}{readOnlyHint} && $names{write_file}{annotations}{openWorldHint},
    'write_file: not read-only, open-world (publishes to the site)' );
ok( $names{delete_file}{annotations}{destructiveHint}, 'delete_file is annotated destructive' );
ok( $names{write_file}{outputSchema}, 'tools carry an output schema (ChatGPT validates results)' );

( $st, $r ) = mcp( { jsonrpc => '2.0', id => 3, method => 'ping' } );
is_deeply( $r->{result}, {}, 'ping: empty result' );

# --- a notification (no id) gets 202, no body ---
( $st, $r ) = mcp( { jsonrpc => '2.0', method => 'notifications/initialized' } );
is( $st, 202, 'notification: 202 Accepted, no JSON-RPC body' );

# --- auth gate: no bearer -> HTTP 401 + WWW-Authenticate (OAuth challenge) ---
my $raw;
( $st, $r, $raw ) = call( 'list_files', { path => '/content' } );    # no Authorization
is( $st, 401, 'tools/call without a bearer -> HTTP 401 (OAuth challenge)' );
like( $raw,
    qr{WWW-Authenticate:\s*Bearer\s+resource_metadata="[^"]+/\.well-known/oauth-protected-resource"},
    '401 carries the protected-resource metadata pointer' );
is( $r->{error}{code}, -32001, 'body is a JSON-RPC unauthorized error' );

( $st, $r ) = call( 'list_files', { path => '/content' }, $bearer_lim );
ok( !$r->{error}, 'authenticated tools/call succeeds' );
ok( !$r->{result}{isError}, 'list_files is not an error' );
my $sc = $r->{result}{structuredContent};
ok( ( grep { $_->{name} eq 'page.md' } @{ $sc->{entries} } ), 'list_files returns page.md' );

# --- a real write through the handler ---
( $st, $r ) = call( 'write_file', { path => '/content/new.md', content => "fresh\n" }, $bearer_lim );
ok( !$r->{result}{isError}, 'write_file succeeds' );
ok( -f "$d/content/new.md", 'write_file created the file on disk' );

# --- capability gate: a webdav-only token cannot activate a theme ---
( $st, $r ) = call( 'activate_theme', { theme => 'sky' }, $bearer_lim );
is( $r->{error}{code}, -32002, 'insufficient capability is rejected (needs manage_themes)' );

# --- the full token may ---
( $st, $r ) = call( 'whoami', {}, $bearer_full );
ok( $r->{result}{structuredContent}{capabilities}{manage_themes},
    'whoami reflects the full grant' );

# --- error taxonomy ---
( $st, $r ) = call( 'no_such_tool', {}, $bearer_full );
is( $r->{error}{code}, -32602, 'unknown tool -> invalid params' );

( $st, $r ) = mcp( { jsonrpc => '2.0', id => 9, method => 'no/such/method' } );
is( $r->{error}{code}, -32601, 'unknown method -> method not found' );

done_testing();
