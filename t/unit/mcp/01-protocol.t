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
make_path( "$d/content", "$d/lazysite/manager/locks", "$d/lazysite/auth", "$d/lazysite/forms" );
open my $hc, '>', "$d/lazysite/forms/handlers.conf" or die $!;
print $hc "handlers:\n  - id: local-storage\n    enabled: true\n    name: Local file storage\n    type: file\n";
close $hc;
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
my %caps = $u =~ /full/ ? (webdav=>1, manage_content=>1, manage_themes=>1, manage_layouts=>1, manage_config=>1)
                        : (webdav=>1, manage_content=>1);
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
ok( $names{invalidate_cache}, 'tools/list advertises invalidate_cache' );
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
is( $r->{error}{data}{reason}, 'sign-in-incomplete', '401 distinguishes sign-in-incomplete (no credential reached the server)' );

( $st, $r ) = call( 'list_files', { path => '/content' }, $bearer_lim );
ok( !$r->{error}, 'authenticated tools/call succeeds' );
ok( !$r->{result}{isError}, 'list_files is not an error' );
my $sc = $r->{result}{structuredContent};
ok( ( grep { $_->{name} eq 'page.md' } @{ $sc->{entries} } ), 'list_files returns page.md' );

# --- a real write through the handler ---
( $st, $r ) = call( 'write_file', { path => '/content/new.md', content => "fresh\n" }, $bearer_lim );
ok( !$r->{result}{isError}, 'write_file succeeds' );
ok( -f "$d/content/new.md", 'write_file created the file on disk' );

# --- replace_text: exact patch edit (no whole-file overwrite) ---
( $st, $r ) = call( 'replace_text', { path => '/content/new.md', old => 'fresh', new => 'updated' }, $bearer_lim );
ok( !$r->{result}{isError}, 'replace_text succeeds' );
is( $r->{result}{structuredContent}{replacements}, 1, 'replace_text reports the replacement count' );
{
    open my $fh, '<', "$d/content/new.md"; local $/; my $c = <$fh>; close $fh;
    like( $c, qr/updated/, 'file content was patched' );
    unlike( $c, qr/fresh/, 'old text gone' );
}
( $st, $r ) = call( 'replace_text', { path => '/content/new.md', old => 'NOPE', new => 'x' }, $bearer_lim );
ok( $r->{result}{structuredContent}{error}, 'replace_text errors when old text is absent (no silent clobber)' );

# --- search_files: grep over content ---
( $st, $r ) = call( 'search_files', { query => 'updated' }, $bearer_lim );
ok( !$r->{result}{isError}, 'search_files succeeds' );
ok( $r->{result}{structuredContent}{count} >= 1, 'search_files finds a match' );
ok( ( grep { ( $_->{path} // '' ) =~ m{new\.md} } @{ $r->{result}{structuredContent}{matches} || [] } ),
    'search_files reports the matching file + path' );

# --- page_status ---
( $st, $r ) = call( 'page_status', { path => '/content/new.md' }, $bearer_lim );
ok( !$r->{result}{isError}, 'page_status succeeds' );
ok( $r->{result}{structuredContent}{exists}, 'page_status: source exists' );
like( $r->{result}{structuredContent}{public_url}, qr{/content/new$}, 'page_status: public URL derived' );

# --- error diagnostics: a missing-file read reports a kind ---
( $st, $r ) = call( 'read_file', { path => '/content/does-not-exist.md' }, $bearer_lim );
is( $r->{result}{structuredContent}{kind}, 'not-found', 'read of a missing file reports kind=not-found' );

# --- page API: read_page + list_pages ---
call( 'write_file', { path => '/content/about.md',
    content => "---\ntitle: About Us\nregister: [sitemap, llms]\n---\nBody text here.\n" }, $bearer_lim );
( $st, $r ) = call( 'read_page', { path => '/content/about.md' }, $bearer_lim );
is( $r->{result}{structuredContent}{front_matter}{title}, 'About Us', 'read_page parses the front-matter title' );
like( $r->{result}{structuredContent}{body}, qr/Body text here/, 'read_page returns the body' );
is_deeply( $r->{result}{structuredContent}{front_matter}{register}, [ 'sitemap', 'llms' ],
    'read_page parses a [list] field' );

( $st, $r ) = call( 'list_pages', {}, $bearer_lim );
ok( $r->{result}{structuredContent}{count} >= 1, 'list_pages returns pages' );
ok( ( grep { $_->{path} eq '/content/about.md' && $_->{title} eq 'About Us' }
        @{ $r->{result}{structuredContent}{pages} || [] } ),
    'list_pages includes the page with its title' );

# --- preview_page: in-channel server-side render ---
( $st, $r ) = call( 'preview_page', { path => '/content/about' }, $bearer_lim );
ok( !$r->{result}{isError} && $r->{result}{structuredContent}{ok}, 'preview_page renders' );
like( $r->{result}{structuredContent}{html}, qr/Body text here/, 'preview_page returns the rendered HTML body' );

# --- validate_page: public-data warning + form-rule check ---
( $st, $r ) = call( 'validate_page', { content =>
    "---\ntitle: Guest Info\n---\nWiFi password: hunter2\nCall +44 20 7946 0958\n" }, $bearer_lim );
my $vw = $r->{result}{structuredContent}{warnings} || [];
ok( ( grep { $_->{kind} eq 'public-credential' } @$vw ), 'validate_page warns on a published password' );
ok( ( grep { $_->{kind} eq 'public-phone' } @$vw ),      'validate_page warns on a phone number' );
( $st, $r ) = call( 'validate_page', { content =>
    "---\ntitle: T\n---\n::: form\nname | Name | requierd\nsubmit | Go\n:::\n" }, $bearer_lim );
ok( ( grep { $_->{kind} eq 'invalid-form-rule' } @{ $r->{result}{structuredContent}{issues} || [] } ),
    'validate_page flags an unknown form rule (typo)' );
( $st, $r ) = call( 'validate_page', { content =>
    "---\ntitle: T\n---\n::: form\ndog | Dog | required select:No,Yes - one small to medium dog\nsubmit | Go\n:::\n" }, $bearer_lim );
ok( !( grep { $_->{kind} eq 'invalid-form-rule' } @{ $r->{result}{structuredContent}{issues} || [] } ),
    'validate_page does not flag the words inside a multi-word select option' );

# --- audit_site: broken link + duplicate block + missing title ---
my $shared = "This exact testimonial paragraph is shared across two pages and is plenty long.";
call( 'write_file', { path => '/content/p1.md', content => "---\ntitle: One\n---\nSee [gone](/content/missing).\n\n$shared\n" }, $bearer_lim );
call( 'write_file', { path => '/content/p2.md', content => "---\n---\n$shared\n" }, $bearer_lim );
( $st, $r ) = call( 'audit_site', {}, $bearer_lim );
my $au = $r->{result}{structuredContent};
ok( ( grep { $_->{to} =~ m{/content/missing} } @{ $au->{broken_links} || [] } ), 'audit_site finds a broken internal link' );
ok( ( grep { $_ eq '/content/p2' } @{ $au->{missing_title} || [] } ), 'audit_site flags a page missing a title' );
ok( ( grep { $_->{pages} && @{ $_->{pages} } >= 2 } @{ $au->{duplicate_blocks} || [] } ), 'audit_site detects a duplicated block across pages' );

# --- SM088: list_form_handlers + bind_form ---
( $st, $r ) = call( 'list_form_handlers', {}, $bearer_lim );
ok( ( grep { $_->{id} eq 'local-storage' && $_->{type} eq 'file' } @{ $r->{result}{structuredContent}{handlers} || [] } ),
    'list_form_handlers returns the configured handler (id + type, no secrets)' );
( $st, $r ) = call( 'bind_form', { form => 'review', handler => 'local-storage' }, $bearer_lim );
ok( !$r->{result}{isError} && $r->{result}{structuredContent}{ok}, 'bind_form succeeds' );
{
    open my $fh, '<', "$d/lazysite/forms/review.conf"; local $/; my $c = <$fh>; close $fh;
    like( $c, qr/handler:\s*local-storage/, 'bind_form wrote a handler reference (no destination/creds)' );
}
( $st, $r ) = call( 'bind_form', { form => 'review', handler => 'no-such' }, $bearer_lim );
is( $r->{result}{structuredContent}{kind}, 'not-found', 'bind_form rejects an unknown handler' );

# --- capability gate: a webdav-only token cannot activate a theme ---
( $st, $r ) = call( 'activate_theme', { theme => 'sky' }, $bearer_lim );
is( $r->{error}{code}, -32002, 'insufficient capability is rejected (needs manage_themes)' );

# --- the full token may ---
( $st, $r ) = call( 'whoami', {}, $bearer_full );
ok( $r->{result}{structuredContent}{capabilities}{manage_themes},
    'whoami reflects the full grant' );
ok( ( grep { $_ eq 'write_file' } @{ $r->{result}{structuredContent}{tools} || [] } ),
    'whoami echoes the full tool manifest (one-call discovery)' );
is( $r->{result}{structuredContent}{auth}{method}, 'bearer',
    'whoami reports the auth method + lifetime (static bearer here)' );

# --- copy_file + get_permissions ---
call( 'copy_file', { from => '/content/about.md', to => '/content/about-copy.md' }, $bearer_lim );
( $st, $r ) = call( 'read_file', { path => '/content/about-copy.md' }, $bearer_lim );
like( $r->{result}{structuredContent}{content}, qr/About Us/, 'copy_file duplicated the content to a new path' );
( $st, $r ) = call( 'get_permissions', { path => '/content/about.md' }, $bearer_lim );
ok( !$r->{result}{isError} && $r->{result}{structuredContent}{ok}, 'get_permissions returns the ACL state' );

# --- error taxonomy ---
( $st, $r ) = call( 'no_such_tool', {}, $bearer_full );
is( $r->{error}{code}, -32602, 'unknown tool -> invalid params' );

( $st, $r ) = mcp( { jsonrpc => '2.0', id => 9, method => 'no/such/method' } );
is( $r->{error}{code}, -32601, 'unknown method -> method not found' );

done_testing();
