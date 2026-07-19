#!/usr/bin/perl
# SEC-2026-07 (M2): a dav_scope-confined partner credential must be confined on
# the MCP channel too, not just over WebDAV. A scoped partner that also holds
# the mcp capability could previously read/write the whole content namespace
# over MCP. Here 'scoped' carries dav_scope=content/clientA and is refused any
# path outside it, while an equivalent unscoped partner is not.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP   qw(encode_json decode_json);
use IPC::Open2;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);

my $root = repo_root();
my $mcp  = "$root/lazysite-mcp.pl";

my $d = tempdir( CLEANUP => 1 );
make_path( "$d/content/clientA", "$d/content/clientB",
    "$d/lazysite/manager/locks", "$d/lazysite/auth" );
open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
print $cf "layout: base\ntheme: sky\nmcp_enabled: true\n";
close $cf;
open my $a, '>', "$d/content/clientA/ok.md"     or die $!; print $a "A\n"; close $a;
open my $b, '>', "$d/content/clientB/secret.md" or die $!; print $b "B\n"; close $b;

# Stub users-tool: 'scoped' gets a dav_scope; everyone gets content + mcp.
my $stub = "$d/users-stub.pl";
open my $sf, '>', $stub or die $!;
print $sf <<'STUB';
#!/usr/bin/perl
use strict; use warnings; use JSON::PP qw(encode_json decode_json);
my $in = do { local $/; <STDIN> };
my $r = eval { decode_json($in) } || {};
my $u = $r->{username} // '';
my %s = ( webdav=>1, manage_content=>1, manage_nav=>1, manage_forms=>1, mcp=>1 );
$s{dav_scopes} = ['content/clientA'] if $u =~ /scoped/;    # SM155: group-derived list
print encode_json({ ok => 1, settings => \%s });
STUB
close $sf;
chmod 0755, $stub;

sub call {
    my ( $tool, $args, $user ) = @_;
    my $payload = { jsonrpc => '2.0', id => 1, method => 'tools/call',
        params => { name => $tool, arguments => $args || {} } };
    my $body = encode_json($payload);
    local %ENV = %ENV;
    $ENV{DOCUMENT_ROOT}       = $d;
    $ENV{REQUEST_METHOD}      = 'POST';
    $ENV{CONTENT_LENGTH}      = length $body;
    $ENV{LAZYSITE_USERS_TOOL} = $stub;
    $ENV{HTTP_AUTHORIZATION}  = "Bearer $user:lzs_x";
    my ( $out, $in );
    my $pid = open2( $out, $in, $^X, $mcp );
    print $in $body;
    close $in;
    my $resp = do { local $/; <$out> };
    close $out;
    waitpid $pid, 0;
    my ($jb) = $resp =~ /\r?\n\r?\n(.*)/s;
    return ( defined $jb && length $jb ) ? eval { decode_json($jb) } : undef;
}

# --- scoped partner: confined to content/clientA ---------------------------
my $in_scope = call( 'read_file', { path => '/content/clientA/ok.md' }, 'scoped' );
ok( !$in_scope->{error}, 'scoped partner may read inside its scope' )
    or diag encode_json($in_scope);

my $out_scope = call( 'read_file', { path => '/content/clientB/secret.md' }, 'scoped' );
is( $out_scope->{error}{code}, -32002,
    'M2: scoped partner is refused a read OUTSIDE its scope' );

my $w = call( 'write_file',
    { path => '/content/clientB/x.md', content => "no\n" }, 'scoped' );
is( $w->{error}{code}, -32002, 'M2: scoped partner is refused a write outside its scope' );
ok( !-f "$d/content/clientB/x.md", 'the out-of-scope write did not land' );

# --- unscoped partner: reaches the whole content namespace -----------------
my $u = call( 'read_file', { path => '/content/clientB/secret.md' }, 'wide' );
ok( !$u->{error}, 'an UNscoped partner (wide) still reaches the whole namespace' )
    or diag encode_json($u);

done_testing();
