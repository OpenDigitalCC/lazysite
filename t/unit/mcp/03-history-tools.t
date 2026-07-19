#!/usr/bin/perl
# SM085 over MCP: the content-history tools (list_versions / view_version /
# restore_version) through the real CGI dispatch. What matters: honest
# enabled:false before the plugin is on, MCP writes become recorded versions
# once it is, view returns the exact historic content plus a diff, restore
# routes through the normal save path and becomes the newest version (nothing
# lost), and the capability gate holds (a no-content partner is refused).
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP qw(encode_json decode_json);
use IPC::Open2;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper qw(repo_root);
use Lazysite::Git ();

plan skip_all => 'git not available' unless Lazysite::Git::git_available();

my $root = repo_root();
my $mcp  = "$root/lazysite-mcp.pl";

my $d = tempdir( CLEANUP => 1 );
make_path( "$d/content", "$d/lazysite/manager/locks", "$d/lazysite/auth", "$d/lazysite/forms" );
open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
print $cf "layout: base\ntheme: sky\nmcp_enabled: true\n";
close $cf;
open my $pg, '>', "$d/content/page.md" or die $!; print $pg "version one\n"; close $pg;

# Stub users-tool (same shape as 01-protocol.t): caps by username.
my $stub = "$d/users-stub.pl";
open my $sf, '>', $stub or die $!;
print $sf <<'STUB';
#!/usr/bin/perl
use strict; use warnings; use JSON::PP qw(encode_json decode_json);
my $in = do { local $/; <STDIN> };
my $r = eval { decode_json($in) } || {};
my $u = $r->{username} // '';
my %caps = $u =~ /theme/ ? (manage_themes=>1, manage_layouts=>1)
         :                 (webdav=>1, manage_content=>1);
$caps{manage_nav} = $caps{manage_forms} = 1 if $caps{manage_content};
$caps{mcp} = 1;
print encode_json({ ok => 1, settings => \%caps });
STUB
close $sf;
chmod 0755, $stub;

sub mcp {
    my ( $payload, %extra ) = @_;
    my $body = defined $payload ? encode_json($payload) : '';
    local %ENV = %ENV;
    $ENV{DOCUMENT_ROOT}       = $d;
    $ENV{REQUEST_METHOD}      = 'POST';
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
    return ( $status, $obj );
}

sub call {
    my ( $tool, $args, $auth ) = @_;
    my ( $st, $r ) = mcp( { jsonrpc => '2.0', id => 1, method => 'tools/call',
        params => { name => $tool, arguments => $args || {} } }, auth => $auth );
    return ( $st, $r );
}
sub sc { return $_[0]->{result}{structuredContent} }

my $agent = 'Bearer historian:lzs_tok';    # webdav + manage_content
my $nocap = 'Bearer themebot:lzs_tok';     # theme-only: no manage_content

# --- advertised + annotated ---------------------------------------------------
my ( $st, $r ) = mcp( { jsonrpc => '2.0', id => 1, method => 'tools/list' } );
my %names = map { $_->{name} => $_ } @{ $r->{result}{tools} };
ok( $names{list_versions} && $names{view_version} && $names{restore_version},
    'tools/list advertises the three history tools' );
ok( $names{list_versions}{annotations}{readOnlyHint}, 'list_versions annotated read-only' );
ok( !$names{restore_version}{annotations}{readOnlyHint}
        && $names{restore_version}{annotations}{openWorldHint},
    'restore_version annotated as a live-site write' );

# --- honest before the plugin is on --------------------------------------------
( $st, $r ) = call( 'list_versions', { path => '/content/page.md' }, $agent );
ok( sc($r)->{ok} && !sc($r)->{enabled}, 'history off: ok with enabled:false (no invented history)' )
    or diag encode_json($r);

# --- enable history (as the operator's plugin toggle would) --------------------
open my $ap, '>>', "$d/lazysite/lazysite.conf" or die $!;
print $ap "git_history: enabled\n";
close $ap;
my $init = Lazysite::Git::init( $d, 'operator' );
ok( $init->{ok}, 'history enabled + adoption commit' ) or diag explain $init;

# --- MCP writes become recorded versions ---------------------------------------
( $st, $r ) = call( 'write_file', { path => '/content/page.md', content => "version two\n" }, $agent );
ok( sc($r)->{ok}, 'write_file v2 through the connector' ) or diag encode_json($r);
( $st, $r ) = call( 'write_file', { path => '/content/page.md', content => "version three\n" }, $agent );
ok( sc($r)->{ok}, 'write_file v3 through the connector' );

( $st, $r ) = call( 'list_versions', { path => '/content/page.md' }, $agent );
my $hist = sc($r);
ok( $hist->{ok} && $hist->{enabled}, 'list_versions: enabled' ) or diag encode_json($r);
cmp_ok( scalar @{ $hist->{entries} }, '>=', 3, 'adoption + both connector writes recorded' );
like( $hist->{entries}[0]{sha}, qr/\A[0-9a-f]{7,40}\z/, 'entries carry version ids' );
like( $hist->{entries}[0]{subject}, qr/edit/, 'connector writes named as edits' );

# --- view: exact historic content + a diff -------------------------------------
my $adoption = $hist->{entries}[-1]{sha};
( $st, $r ) = call( 'view_version', { path => '/content/page.md', version => $adoption }, $agent );
is( sc($r)->{content}, "version one\n", 'view_version returns the exact historic content' );
like( sc($r)->{diff}, qr/version three/, 'and a diff against the current file' );

# --- restore: through the save path, becomes the newest version ----------------
( $st, $r ) = call( 'restore_version', { path => '/content/page.md', version => $adoption }, $agent );
ok( sc($r)->{ok}, 'restore_version ok' ) or diag encode_json($r);
open my $now, '<', "$d/content/page.md" or die $!;
is( do { local $/; <$now> }, "version one\n", 'file content restored' );
close $now;
( $st, $r ) = call( 'list_versions', { path => '/content/page.md' }, $agent );
cmp_ok( scalar @{ sc($r)->{entries} }, '>=', 4, 'the restore itself is the newest recorded version' );
like( sc($r)->{entries}[0]{subject}, qr/restore/i, 'named as a restore' )
    or diag encode_json( sc($r)->{entries} );

# --- capability gate ------------------------------------------------------------
( $st, $r ) = call( 'list_versions', { path => '/content/page.md' }, $nocap );
is( $r->{error}{code}, -32002, 'a partner without manage_content is refused' );

done_testing();
