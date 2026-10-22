#!/usr/bin/perl
# SM976 Q15f (ruled 2026-10-09, "Fix: per-tool path args"): each MCP tool
# declares which of its arguments are content paths, and the scope pass checks
# those and no others.
#
# SM661 named the path arguments once for every tool (path, to, from, slug, old,
# new), so replace_text's `old` and `new` - the text it finds and the text it
# puts in - were checked as paths: a grant scoped to sites/alpha was refused
# "Path 'title: Plain' is outside your assigned scope" on its own page. Fails
# closed, and made the tool unusable to every scoped grant. rename_page's
# `old`/`new` ARE paths and stay checked.
#
# WHAT IS ASSERTED, on a grant scoped to sites/alpha (the stub's PROBE_SCOPED):
#   the grant is genuinely scoped (write_file outside is refused)
#   replace_text edits ordinary text inside its scope - even text shaped like a
#     path outside it, or like an engine path the carve-out guards
#   replace_text on a FILE outside its scope is refused: `path` is still checked
#   rename_page still checks old and new
#   EVERY tool keeps the check it had: each argument each tool declares is
#     refused outside the scope, one call per (tool, argument) - the before/after
#     list, measured
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use JSON::PP   qw(encode_json decode_json);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root env_passthrough site_tempdir run_child);

my $root    = repo_root();
my $docroot = site_tempdir();
make_path( "$docroot/lazysite/auth", "$docroot/sites/alpha", "$docroot/sites/beta" );
{
    open my $cf, '>', "$docroot/lazysite/lazysite.conf" or die $!;
    print {$cf} "site_name: T\nmcp_enabled: true\n";
    close $cf;
}
my $stub = "$docroot/users-stub.pl";
{
    open my $sf, '>', $stub or die $!;
    print {$sf} <<'STUB';
#!/usr/bin/perl
use JSON::PP qw(encode_json);
my %s = map { $_ => 1 } qw(manage_content mcp api manage_briefs manage_forms read_submissions manage_nav purge);
$s{dav_scopes} = ['/sites/alpha'] if $ENV{PROBE_SCOPED};
print encode_json( { ok => 1, settings => \%s } );
STUB
    close $sf;
    chmod 0755, $stub;
}

sub spit {
    my ( $p, $t ) = @_;
    open my $fh, '>', "$docroot/$p" or die "$p: $!";
    print {$fh} $t;
    close $fh;
    return;
}
sub slurp { open my $fh, '<', "$docroot/$_[0]" or return undef; local $/; return <$fh> }

sub mcp {
    my ( $tool, $args, %opt ) = @_;
    my $body = encode_json(
        { jsonrpc => '2.0', id => 1, method => 'tools/call', params => { name => $tool, arguments => $args } } );
    local %ENV = ( env_passthrough(),
        DOCUMENT_ROOT       => $docroot,
        REQUEST_METHOD      => 'POST',
        CONTENT_LENGTH      => length $body,
        LAZYSITE_USERS_TOOL => $stub,
        HTTP_AUTHORIZATION  => 'Bearer tester:lzs_tok',
        ( $opt{scoped} ? ( PROBE_SCOPED => 1 ) : () ),
    );
    my $resp = run_child( [ $^X, "$root/lazysite-mcp.pl" ],
        stdin => $body, stderr => 'inherit' )->{out};
    my ($jb) = $resp =~ /\r?\n\r?\n(.*)/s;
    return eval { decode_json($jb) } || {};
}
sub rpc_refusal { return ( $_[0]->{error} && $_[0]->{error}{message} ) // '' }
sub result      { return $_[0]->{result} ? $_[0]->{result}{structuredContent} || {} : {} }

# --- the grant is genuinely scoped -----------------------------------------
my $w = mcp( 'write_file', { path => '/sites/beta/x.md', content => 'hi' }, scoped => 1 );
like( rpc_refusal($w), qr/outside your assigned scope/, 'write_file outside the scope is refused (the grant IS scoped)' )
    or BAIL_OUT('the fixture is not confined - nothing below would test anything');

# --- replace_text: old and new are text ------------------------------------
spit( 'sites/alpha/p.md', "---\ntitle: Plain\n---\nSee sites/beta/elsewhere and lazysite/nav.conf.\n" );
spit( 'sites/beta/q.md', "---\ntitle: Plain\n---\nbody\n" );

my $r = mcp( 'replace_text', { path => 'sites/alpha/p.md', old => 'title: Plain', new => 'title: Changed' }, scoped => 1 );
is( rpc_refusal($r), '', 'replace_text inside the scope is not refused for its text' );
ok( result($r)->{ok}, '...and succeeds' ) or diag( encode_json($r) );
like( slurp('sites/alpha/p.md'), qr/^title: Changed$/m, '...and the page changed' );

$r = mcp( 'replace_text', { path => 'sites/alpha/p.md', old => 'sites/beta/elsewhere', new => 'sites/beta/other' },
    scoped => 1 );
ok( result($r)->{ok}, 'replace_text: text shaped like a path outside the scope is text' ) or diag( encode_json($r) );
like( slurp('sites/alpha/p.md'), qr{sites/beta/other}, '...and was replaced' );

$r = mcp( 'replace_text', { path => 'sites/alpha/p.md', old => 'lazysite/nav.conf', new => 'lazysite/nav.conf!' },
    scoped => 1 );
ok( result($r)->{ok}, 'replace_text: text shaped like an engine path is not asked the carve-out' )
    or diag( encode_json($r) );

$r = mcp( 'replace_text', { path => 'sites/beta/q.md', old => 'title: Plain', new => 'title: Owned' }, scoped => 1 );
like( rpc_refusal($r), qr/Path 'sites\/beta\/q\.md' is outside your assigned scope/,
    'replace_text on a file outside the scope is refused: path is still checked' );
like( slurp('sites/beta/q.md'), qr/^title: Plain$/m, '...and the file is untouched' );

$r = mcp( 'replace_text', { path => 'sites/beta/q.md', old => 'title: Plain', new => 'title: Unscoped' } );
ok( result($r)->{ok}, 'an unscoped grant edits it' );

# --- rename_page: old and new are paths ------------------------------------
spit( 'sites/alpha/r.md', "---\ntitle: R\n---\nbody\n" );
$r = mcp( 'rename_page', { old => 'sites/alpha/r', new => 'sites/beta/r' }, scoped => 1 );
like( rpc_refusal($r), qr/Path 'sites\/beta\/r' is outside your assigned scope/, 'rename_page: new outside is refused' );
ok( -e "$docroot/sites/alpha/r.md" && !-e "$docroot/sites/beta/r.md", '...and nothing moved' );
$r = mcp( 'rename_page', { old => 'sites/beta/q', new => 'sites/alpha/q' }, scoped => 1 );
like( rpc_refusal($r), qr/Path 'sites\/beta\/q' is outside your assigned scope/, 'rename_page: old outside is refused' );
$r = mcp( 'rename_page', { old => 'sites/alpha/r', new => 'sites/alpha/r2' }, scoped => 1 );
is( rpc_refusal($r), '', 'rename_page inside the scope is not refused' );

# --- every tool keeps the check it had -------------------------------------
# The before list: every argument named path, to, from, slug, old or new in each
# tool's schema was scope-checked (SM661's one list). After: the same, less
# replace_text's old and new. One call per pair, the argument pointing outside
# the scope; the scope pass runs before the arguments are validated, so the
# other arguments are not needed to reach it.
my %KEEPS = (
    list_files => ['path'], read_file => ['path'], upload_file => ['path'], write_file => ['path'],
    read_brief          => ['path'], append_brief => ['path'], delete_brief => ['path'],
    preview_public_page => ['path'], replace_text => ['path'], copy_file => [qw(to from)],
    get_permissions => ['path'], move_file   => [qw(to from)], delete_file   => ['path'],
    set_permissions => ['path'], create_form => ['path'],      validate_page => ['path'],
    create_page => ['slug'], delete_page => [qw(path slug)], rename_page => [qw(old new)],
    read_page    => ['path'], preview_page     => ['path'],  page_status   => ['path'],
    search_files => ['path'], invalidate_cache => ['path'],  list_versions => ['path'],
    view_version => ['path'], restore_version  => ['path'],
);
for my $tool ( sort keys %KEEPS ) {
    for my $arg ( @{ $KEEPS{$tool} } ) {
        my $res = mcp( $tool, { $arg => 'sites/beta/q.md' }, scoped => 1 );
        like( rpc_refusal($res), qr/outside your assigned scope/, "$tool: '$arg' outside the scope is refused" );
    }
}
for my $arg (qw(old new)) {
    my $res = mcp( 'replace_text', { path => 'sites/alpha/p.md', $arg => 'sites/beta/q.md' }, scoped => 1 );
    unlike( rpc_refusal($res), qr/outside your assigned scope/, "replace_text: '$arg' is text, not scope-checked" );
}

done_testing();
