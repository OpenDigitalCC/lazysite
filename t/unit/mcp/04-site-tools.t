#!/usr/bin/perl
# SM158/SM160: the MCP site_backup / site_apply tools. Both need manage_domains
# and access (scope) to the target domain. This exercises the success and the
# refusal branches (no such domain, outside scope, bad/absent package) so the
# tool run subs are covered.
use strict;
use warnings;
use Test::More;
use JSON::PP    qw(encode_json decode_json);
use IPC::Open2  qw(open2);
use File::Temp  qw(tempdir);
use File::Path  qw(make_path);
use FindBin;

my $root = "$FindBin::Bin/../../..";
my $mcp  = "$root/lazysite-mcp.pl";
my $d    = tempdir( CLEANUP => 1 );
make_path( "$d/lazysite/auth", "$d/lazysite/backups", "$d/lazysite/layouts/base/themes/blue", "$d/sites/clienta" );

# A configured domain with its own content root + theme/layout, so site_backup
# has something real to package.
open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
print {$cf} "site_name: Agency\nmcp_enabled: true\nalias_hosts: shop.clienta.com\n"
    . "alias.shop.clienta.com.content_root: sites/clienta\n"
    . "alias.shop.clienta.com.theme: blue\n"
    . "alias.shop.clienta.com.layout: base\n";
close $cf;
open my $ix, '>', "$d/sites/clienta/index.md" or die $!; print {$ix} "# A\n"; close $ix;
open my $lt, '>', "$d/lazysite/layouts/base/layout.tt" or die $!; print {$lt} '[% content %]'; close $lt;
open my $th, '>', "$d/lazysite/layouts/base/themes/blue/theme.json" or die $!; print {$th} '{}'; close $th;

# Stub users-tool. Everyone gets mcp + manage_domains; a /scoped/ username is
# additionally confined to content/other (so shop.clienta.com is out of scope).
my $stub = "$d/users-stub.pl";
open my $sf, '>', $stub or die $!;
print $sf <<'STUB';
#!/usr/bin/perl
use strict; use warnings; use JSON::PP qw(encode_json decode_json);
my $in = do { local $/; <STDIN> };
my $r  = eval { decode_json($in) } || {};
my $u  = $r->{username} // '';
my %caps = ( mcp => 1, manage_content => 1, manage_domains => 1 );
$caps{dav_scopes} = ['content/other'] if $u =~ /scoped/;
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
sub sc { my $r = shift; $r && $r->{result} ? $r->{result}{structuredContent} : undef }

my $ok     = 'Bearer agent:lzs_tok';          # manage_domains, unconfined
my $scoped = 'Bearer scopedagent:lzs_tok';    # manage_domains, confined to content/other

# --- site_backup: happy path packages the domain ----------------------------
{
    my $r = sc( call( 'site_backup', { host => 'shop.clienta.com' }, $ok ) );
    ok( $r && $r->{ok}, 'site_backup packages a configured domain' ) or diag encode_json($r);
    like( $r->{name}, qr/^lazysite-site-shop\.clienta\.com-/, 'package named for the host' );
}

# --- site_backup: refusals --------------------------------------------------
{
    # SM278: a missing REQUIRED argument is refused by the schema gate before
    # the tool runs, so it arrives as a JSON-RPC error naming the argument
    # rather than as a tool result with ok:0. Stronger than the old assertion -
    # it pins that the caller is told WHICH argument is missing.
    my $none = call( 'site_backup', {}, $ok );
    ok( $none && $none->{error} && $none->{error}{message} =~ /Missing required argument 'host'/,
        'site_backup needs a host, and says which' )
        or diag encode_json($none);

    my $nope = sc( call( 'site_backup', { host => 'nope.example' }, $ok ) );
    ok( !$nope->{ok} && $nope->{error} =~ /configured/i,
        'site_backup refuses a domain this instance does not serve' );

    my $oos = sc( call( 'site_backup', { host => 'shop.clienta.com' }, $scoped ) );
    ok( !$oos->{ok} && $oos->{error} =~ /scope|access/i,
        'site_backup refuses a domain outside the agent scope' );
}

# --- site_apply: refusals (no need for a real package to hit these) ----------
{
    my $bad = sc( call( 'site_apply', { name => 'not-a-package.txt' }, $ok ) );
    ok( !$bad->{ok} && $bad->{error} =~ /package/i, 'site_apply rejects a non-package name' );

    my $missing = sc( call( 'site_apply', { name => 'lazysite-site-ghost-20260101T000000Z.tar.gz' }, $ok ) );
    ok( !$missing->{ok} && $missing->{error} =~ /not found/i, 'site_apply reports a missing package' );

    my $oos = sc( call( 'site_apply',
        { name => 'lazysite-site-ghost-20260101T000000Z.tar.gz', host => 'shop.clienta.com' }, $scoped ) );
    ok( !$oos->{ok}, 'site_apply refuses a target outside the agent scope' );
}

# --- round-trip: create then apply to the same domain (clean) ---------------
{
    my $made = sc( call( 'site_backup', { host => 'shop.clienta.com' }, $ok ) );
    my $ap   = sc( call( 'site_apply',
        { name => $made->{name}, host => 'shop.clienta.com', clean => JSON::PP::true() }, $ok ) );
    ok( $ap && $ap->{ok}, 'site_apply applies a package to a configured domain' ) or diag encode_json($ap);
    is( $ap->{applied_to}, 'shop.clienta.com', 'apply reports the target host' );
}

done_testing();
