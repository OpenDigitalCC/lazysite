#!/usr/bin/perl
# SM126: the MCP `mcp` channel gate + the describe_capabilities introspection
# tool. A session without the mcp capability is refused on any real tool, but
# introspection (whoami, describe_capabilities) stays open so a capless agent
# can self-diagnose. describe_capabilities returns the capability map.
use strict;
use warnings;
use Test::More;
use JSON::PP qw(encode_json decode_json);
use IPC::Open2 qw(open2);
use File::Temp qw(tempdir);
use FindBin;

my $root = "$FindBin::Bin/../../..";
my $mcp  = "$root/lazysite-mcp.pl";
my $d    = tempdir( CLEANUP => 1 );
mkdir "$d/lazysite"; mkdir "$d/lazysite/auth";
# MCP surface must be enabled (0.9.0 killswitch, default off).
open my $mcpcf, '>', "$d/lazysite/lazysite.conf" or die $!;
print $mcpcf "site_name: T\nmcp_enabled: true\n";
close $mcpcf;

# Stub users-tool: an mcp cap for everyone EXCEPT a /nomcp/ username.
my $stub = "$d/users-stub.pl";
open my $sf, '>', $stub or die $!;
print $sf <<'STUB';
#!/usr/bin/perl
use strict; use warnings; use JSON::PP qw(encode_json decode_json);
my $in = do { local $/; <STDIN> };
my $r = eval { decode_json($in) } || {};
my $u = $r->{username} // '';
my %caps = (webdav=>1, manage_content=>1, manage_nav=>1, manage_forms=>1, ui=>1);
$caps{mcp} = 1 unless $u =~ /nomcp/;
$caps{manager_ui} = 1 if $u =~ /mgr/;   # SM127: the group-granted `ui` capability
$caps{ui} = 0 if $u =~ /agent/;         # interactive login DISABLED => a dedicated agent account
print encode_json({ ok => 1, settings => \%caps });
STUB
close $sf;
chmod 0755, $stub;

sub mcp {
    my ( $payload, %extra ) = @_;
    my $body = encode_json($payload);
    local %ENV = %ENV;
    $ENV{DOCUMENT_ROOT}       = $d;
    $ENV{REQUEST_METHOD}      = 'POST';
    $ENV{CONTENT_LENGTH}      = length $body;
    $ENV{LAZYSITE_USERS_TOOL} = $stub;
    $ENV{HTTP_AUTHORIZATION}  = $extra{auth} if defined $extra{auth};
    my ( $out, $in );
    my $pid = open2( $out, $in, $^X, $mcp );
    print $in $body; close $in;
    my $resp = do { local $/; <$out> };
    close $out; waitpid $pid, 0;
    my ($jb) = $resp =~ /\r?\n\r?\n(.*)/s;
    return ( defined $jb && length $jb ) ? eval { decode_json($jb) } : undef;
}
sub call { mcp( { jsonrpc => '2.0', id => 1, method => 'tools/call',
    params => { name => $_[0], arguments => $_[1] || {} } }, auth => $_[2] ) }
# MCP wraps a tool's return in result.structuredContent.
sub sc { my $r = shift; $r && $r->{result} ? $r->{result}{structuredContent} : undef }

my $nomcp = 'Bearer clientnomcp:lzs_tok';   # webdav+content, NO mcp channel
my $ok    = 'Bearer clientok:lzs_tok';      # has mcp

# --- SM127: an INTERACTIVE manager account (ui capability + login enabled) is
#     refused on mcp even WITH the mcp cap ---
my $mgr = call( 'list_files', { path => '/' }, 'Bearer clientmgr:lzs_tok' );
is( $mgr->{error}{code}, -32002, 'interactive manager account refused on mcp' );
like( $mgr->{error}{message}, qr/manager|interactive/i, 'denial explains the manager-remote rule' );

# ...but INTROSPECTION stays open even for a manager account (SM126/SM072) -
# whoami must never be refused (the previous ordering wrongly blocked it).
my $mgrw = sc( call( 'whoami', {}, 'Bearer clientmgr:lzs_tok' ) );
ok( $mgrw->{ok}, 'manager account: whoami still allowed (introspection open)' );

# --- an AGENT account (has the manager ui capability from a group, but its
#     interactive login is disabled, ui:false) is a deliberate agent - NOT blocked ---
my $agent = call( 'list_files', { path => '/' }, 'Bearer clientagentmgr:lzs_tok' );
isnt( ( $agent->{error} && $agent->{error}{code} ) // 0, -32002,
    'agent account (manager caps, login disabled) is NOT blocked on mcp' );

# --- A session without the mcp cap is refused on a real tool ----------------
my $r = call( 'list_files', { path => '/' }, $nomcp );
is( $r->{error}{code}, -32002, 'no-mcp session: real tool refused with -32002' );
like( $r->{error}{message}, qr/mcp/, 'denial names the mcp capability' );

# --- ...but introspection stays open ---------------------------------------
my $w = sc( call( 'whoami', {}, $nomcp ) );
ok( $w->{ok}, 'no-mcp session: whoami still allowed (introspection)' );

my $dc = sc( call( 'describe_capabilities', {}, $nomcp ) );
ok( $dc->{ok}, 'no-mcp session: describe_capabilities allowed' );
ok( !$dc->{holds}{capabilities}{mcp}, 'holds shows mcp not granted' );
ok( $dc->{channels}{mcp}{enforced}, 'map reports mcp channel enforced' );

# --- A session WITH mcp gets the full map + can call tools -------------------
my $dc2 = sc( call( 'describe_capabilities', {}, $ok ) );
ok( $dc2->{ok}, 'mcp session: describe_capabilities ok' );
ok( $dc2->{holds}{capabilities}{mcp}, 'holds shows mcp granted' );
ok( exists $dc2->{capabilities}{manage_content}, 'map lists an action capability' );
ok( @{ $dc2->{tasks} } >= 3, 'map carries task recipes' );

my $lf = call( 'list_files', { path => '/' }, $ok );
isnt( ( $lf->{error} && $lf->{error}{code} ) // 0, -32002,
    'mcp session: real tool NOT blocked by the channel gate' );

done_testing();
