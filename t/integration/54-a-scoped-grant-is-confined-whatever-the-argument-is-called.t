#!/usr/bin/perl
# SM661: a scoped partner created and moved content outside its scope.
#
# MEASURED, not reasoned. A grant with dav_scopes ['/sites/alpha'] was refused
# write_file to /sites/beta/x.md - "Path is outside your assigned scope" - and
# in the same session created /sites/beta/sneaky.md through create_page and
# moved a page from alpha into beta through rename_page.
#
# The cause was a hardcoded qw(path to from) in both confinement passes.
# create_page declares `slug`; rename_page declares `old` and `new`. Nothing
# was malformed - the calls were well-formed and the tools did exactly what
# they advertise; the confinement simply never looked at the argument carrying
# the path.
#
# THE REFUSAL ON write_file IS PART OF THE TEST, not scenery: without it, a
# fixture whose grant was not really scoped would pass every assertion below
# by confining nothing and refusing nothing.
#
# WHAT IS ASSERTED
#   the scoped grant is genuinely scoped - write_file outside is refused
#   create_page outside the scope is refused, and writes nothing
#   rename_page out of the scope is refused, and moves nothing
#   the SAME grant still creates INSIDE its scope - not over-confined
#   an UNSCOPED grant is unaffected
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP   qw(encode_json decode_json);
use IPC::Open2;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root env_passthrough);

my $root    = repo_root();
my $docroot = tempdir( CLEANUP => 1 );
make_path( "$docroot/lazysite/auth", "$docroot/sites/alpha", "$docroot/sites/beta" );
open my $cf, '>', "$docroot/lazysite/lazysite.conf" or die $!;
print {$cf} "site_name: T\nmcp_enabled: true\n";
close $cf;

# The scope is switched by an env var the stub reads, so BOTH grants come from
# one fixture and the only difference between them is the confinement.
my $stub = "$docroot/users-stub.pl";
open my $sf, '>', $stub or die $!;
print {$sf} <<'STUB';
#!/usr/bin/perl
use JSON::PP qw(encode_json);
my %s = ( manage_content => 1, mcp => 1, api => 1 );
$s{dav_scopes} = ['/sites/alpha'] if $ENV{PROBE_SCOPED};
print encode_json( { ok => 1, settings => \%s } );
STUB
close $sf;
chmod 0755, $stub;

sub mcp {
    my ( $tool, $args, %opt ) = @_;
    my $body = encode_json( { jsonrpc => '2.0', id => 1, method => 'tools/call',
            params => { name => $tool, arguments => $args } } );
    local %ENV = ( env_passthrough(),
        DOCUMENT_ROOT       => $docroot,
        REQUEST_METHOD      => 'POST',
        CONTENT_LENGTH      => length $body,
        LAZYSITE_USERS_TOOL => $stub,
        HTTP_AUTHORIZATION  => 'Bearer tester:lzs_tok',
        ( $opt{scoped} ? ( PROBE_SCOPED => 1 ) : () ),
    );
    my ( $out, $in );
    my $pid = open2( $out, $in, $^X, "$root/lazysite-mcp.pl" );
    print {$in} $body;
    close $in;
    my $resp = do { local $/; <$out> };
    close $out;
    waitpid $pid, 0;
    my ($jb) = $resp =~ /\r?\n\r?\n(.*)/s;
    return eval { decode_json($jb) } || {};
}
sub refused { return ( $_[0]->{error} && $_[0]->{error}{message} ) ? 1 : 0 }

# --- the grant is genuinely scoped -----------------------------------------
my $w = mcp( 'write_file',
    { path => '/sites/beta/x.md', content => 'hi' }, scoped => 1 );
ok( refused($w), 'write_file outside the scope is refused (the grant IS scoped)' )
    or BAIL_OUT('the fixture is not confined - nothing below would test anything');
like( $w->{error}{message}, qr/outside your assigned scope/,
    'and says so' );

# --- create_page: the escape -----------------------------------------------
my $c = mcp( 'create_page',
    { slug => 'sites/beta/sneaky', title => 'S', body => 'b' }, scoped => 1 );
ok( refused($c),
    'create_page outside the scope is refused - `slug` carries a path too' )
    or diag( 'This is the escape: a well-formed call the confinement never '
        . 'looked at, because the argument was not called `path`.' );
ok( !-e "$docroot/sites/beta/sneaky.md",
    'and nothing was written - the refusal is the confinement, not a message' );

# --- rename_page: the same, moving an existing page ------------------------
open my $pg, '>', "$docroot/sites/alpha/p.md" or die $!;
print {$pg} "---\ntitle: A\n---\nbody\n";
close $pg;
my $r = mcp( 'rename_page',
    { old => 'sites/alpha/p', new => 'sites/beta/moved' }, scoped => 1 );
ok( refused($r), 'rename_page OUT of the scope is refused' );
ok( -e "$docroot/sites/alpha/p.md", 'the page is still where it was' );
ok( !-e "$docroot/sites/beta/moved.md", 'and did not arrive outside the scope' );

# --- not over-confined -----------------------------------------------------
# The fix must not confine a partner out of its OWN content, which is the
# failure that would be reported as an outage rather than found by an audit.
my $ok = mcp( 'create_page',
    { slug => 'sites/alpha/fine', title => 'F', body => 'b' }, scoped => 1 );
ok( !refused($ok), 'the same grant still creates INSIDE its scope' )
    or diag( $ok->{error}{message} // 'no message' );
ok( -e "$docroot/sites/alpha/fine.md", 'and the page is there' );

# --- an unscoped grant is unaffected ---------------------------------------
my $u = mcp( 'create_page',
    { slug => 'sites/beta/allowed', title => 'A', body => 'b' } );
ok( !refused($u), 'an unscoped grant is not confined by this' );
ok( -e "$docroot/sites/beta/allowed.md", 'and writes where it asked' );

done_testing();
