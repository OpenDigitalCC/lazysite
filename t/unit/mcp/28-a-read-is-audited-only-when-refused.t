#!/usr/bin/perl
# SM943 ruling 1 (2026-10-09), the MCP door: "Audit is useful to see when a
# person or agent has made material behaviour changes, authentication events and
# errors. General site activity is of less interest and creates noise. Surfaces
# should be consistent. Drop all 17."
#
# So, driven through the real dispatcher rather than read off the tool table:
#   - a read that SUCCEEDS writes no audit row - including the seventeen reads
#     (read_notices, describe_capabilities, ...) this trail used to record while
#     the control API skipped their twins;
#   - a read that is REFUSED by its handler, or refused at the capability gate,
#     still writes a `fail` row;
#   - a write is audited as before.
# The control API's half is t/unit/manager/206; t/lint/23 holds the two to one
# declaration.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use JSON::PP   qw(encode_json decode_json);
use IPC::Open2;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root site_tempdir);

my $mcp = repo_root() . '/lazysite-mcp.pl';
plan skip_all => "no $mcp" unless -f $mcp;

my $d = site_tempdir();
make_path( "$d/lazysite/manager/locks", "$d/lazysite/auth", "$d/lazysite/logs" );
open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
print {$cf} "layout: base\ntheme: sky\nmcp_enabled: true\n";
close $cf;
open my $pg, '>', "$d/here.md" or die $!;
print {$pg} "---\ntitle: Here\n---\nbody\n";
close $pg;

# Stub users-tool: 'agent' reads content and the bell; 'nobell' lacks the bell.
my $stub = "$d/users-stub.pl";
open my $sf, '>', $stub or die $!;
print {$sf} <<'STUB';
#!/usr/bin/perl
use strict; use warnings; use JSON::PP qw(encode_json decode_json);
my $in = do { local $/; <STDIN> };
my $r = eval { decode_json($in) } || {};
my $u = $r->{username} // '';
my %s = ( mcp => 1, manage_content => 1 );
$s{notifications} = 1 if $u eq 'agent';
print encode_json({ ok => 1, settings => \%s });
STUB
close $sf;
chmod 0755, $stub;

sub call {
    my ( $tool, $args, $user ) = @_;
    my $body = encode_json( { jsonrpc => '2.0', id => 1, method => 'tools/call',
            params => { name => $tool, arguments => $args || {} } } );
    local %ENV = %ENV;
    $ENV{DOCUMENT_ROOT}       = $d;
    $ENV{REQUEST_METHOD}      = 'POST';
    $ENV{CONTENT_LENGTH}      = length $body;
    $ENV{LAZYSITE_USERS_TOOL} = $stub;
    $ENV{HTTP_AUTHORIZATION}  = 'Bearer ' . ( $user // 'agent' ) . ':lzs_x';
    my $pid = open2( my $out, my $in, $^X, $mcp );
    print {$in} $body;
    close $in;
    my $resp = do { local $/; <$out> };
    close $out;
    waitpid $pid, 0;
    my ($jb) = $resp =~ /\r?\n\r?\n(.*)/s;
    return ( defined $jb && length $jb ) ? eval { decode_json($jb) } : undef;
}

my $log = "$d/lazysite/logs/audit.log";
sub rows_since {
    my ($from) = @_;
    open my $fh, '<', $log or return ();
    my @l = <$fh>;
    close $fh;
    return @l[ $from .. $#l ];
}
sub mark { my @all = rows_since(0); return scalar @all }

# --- a read that succeeds is site activity: no row ------------------------
for my $c ( [ read_file => { path => '/here.md' } ], [ read_notices => {} ],
    [ describe_capabilities => {} ] )
{
    my ( $tool, $args ) = @$c;
    my $m = mark();
    my $r = call( $tool, $args );
    ok( $r && $r->{result} && !$r->{result}{isError}, "$tool succeeds" )
        or diag encode_json($r);
    my @new = grep { /\| \Q$tool\E \|/ } rows_since($m);
    is( scalar @new, 0, "a successful $tool writes no audit row" ) or diag @new;
}

# --- a read refused by its handler is an error: one `fail` row ------------
{
    my $m = mark();
    my $r = call( 'read_file', { path => '/not-there.md' } );
    ok( $r && $r->{result} && $r->{result}{isError}, 'read_file of a missing file is refused' )
        or diag encode_json($r);
    my @new = grep { /\| read_file \|/ } rows_since($m);
    is( scalar @new, 1, 'the refused read writes one audit row' );
    like( $new[0] // '', qr/\| fail \| mcp \|/, '...a fail row on the mcp origin' );
    like( $new[0] // '', qr{not-there\.md},     '...naming the path it was refused' );
}

# --- a read refused at the capability gate: still recorded ----------------
{
    my $m = mark();
    my $r = call( 'read_notices', {}, 'nobell' );
    is( $r && $r->{error} && $r->{error}{code}, -32002, 'read_notices without the capability is refused' );
    my @new = grep { /\| read_notices \|/ } rows_since($m);
    is( scalar @new, 1, 'the refused read writes one audit row' );
    like( $new[0] // '', qr/\| fail \| mcp \| denied: needs notifications/,
        '...naming the capability it lacked' );
}

# --- a write is audited, as it always was ---------------------------------
{
    my $m = mark();
    my $r = call( 'write_file', { path => '/new.md', content => "---\ntitle: N\n---\nx\n" } );
    ok( $r && $r->{result} && !$r->{result}{isError}, 'write_file succeeds' ) or diag encode_json($r);
    my @new = grep { /\| create \|/ } rows_since($m);
    is( scalar @new, 1, 'a write writes its audit row' );
    like( $new[0] // '', qr/\| ok \| mcp\b/, '...an ok row on the mcp origin' );
}

done_testing();
