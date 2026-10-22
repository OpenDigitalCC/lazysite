#!/usr/bin/perl
# SM977: MCP create_form adds the form to the page it names, and never replaces
# a page it did not read.
#
# The tool's contract: "Inserts a native :::form block into the page and sets
# its form: NAME front matter", the path "created if absent". It read the
# caller's spelling of the path and wrote the resolved one, so the idiomatic
# extensionless call - create_form {path: "/about"} - read '/about', found
# nothing, and replaced /about.md with a fresh scaffold (the n317 agent's probe,
# tmp/q15f-create-form-probe.pl). A page with text and no front matter was
# replaced too, whatever spelling was used.
#
# The probe's call is the first case. The page's own text must survive, the
# form must be the one the processor renders, and nothing the tool cannot read
# is ever written.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use JSON::PP   qw(encode_json decode_json);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root env_passthrough run_processor site_tempdir run_child);

my $root    = repo_root();
my $docroot = site_tempdir();
make_path("$docroot/lazysite/auth");

sub spit { my ( $p, $t ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh; return }
sub slurp { open my $fh, '<', $_[0] or return ''; local $/; return scalar <$fh> }

spit( "$docroot/lazysite/lazysite.conf", "site_name: T\nmcp_enabled: true\n" );
my $stub = "$docroot/users-stub.pl";
spit( $stub, "#!/usr/bin/perl\nuse JSON::PP qw(encode_json);\n"
        . "print encode_json({ ok => 1, settings => { manage_content => 1, "
        . "manage_forms => 1, api => 1, mcp => 1 } });\n" );
chmod 0755, $stub;

sub mcp {
    my ( $tool, $args ) = @_;
    my $body = encode_json( { jsonrpc => '2.0', id => 1, method => 'tools/call',
            params => { name => $tool, arguments => $args } } );
    local %ENV = ( env_passthrough(),
        DOCUMENT_ROOT       => $docroot,
        REQUEST_METHOD      => 'POST',
        CONTENT_LENGTH      => length $body,
        LAZYSITE_USERS_TOOL => $stub,
        HTTP_AUTHORIZATION  => 'Bearer tester:lzs_tok',
    );
    my $resp = run_child( [ $^X, "$root/lazysite-mcp.pl" ],
        stdin => $body, stderr => 'inherit' )->{out};
    my ($jb) = $resp =~ /\r?\n\r?\n(.*)/s;
    my $d    = eval { decode_json($jb) } || {};
    return eval { decode_json( $d->{result}{content}[0]{text} // '' ) } || {};
}

my $ABOUT = "---\ntitle: About us\n---\n\nTwo paragraphs of real content.\n";

# --- the probe: an extensionless path on an existing page ----------------------
spit( "$docroot/about.md", $ABOUT );
my $r = mcp( 'create_form', { path => '/about', name => 'contact' } );
ok( $r->{ok}, 'create_form on /about succeeds' ) or diag explain $r;
my $about = slurp("$docroot/about.md");
like( $about, qr/^title: About us$/m,               'the page keeps its title' );
like( $about, qr/Two paragraphs of real content\./, 'and its text' );
unlike( $about, qr/^title: Contact$/m, 'it is not replaced by a scaffold' );
like( $about, qr/^form: contact$/m,         'it binds the form' );
like( $about, qr/real content\..*:::form/s, 'the form block follows the text' );
ok( !-e "$docroot/about", 'no extensionless file is written beside it' );
my $html = run_processor( $docroot, '/about' );
like( $html, qr/real content/, 'the served page still carries its text' );
like( $html, qr/<form/i,       'and renders the form' );

# --- the .md spelling reads the same file ------------------------------------
spit( "$docroot/team.md", "---\ntitle: Team\n---\n\nThe team.\n" );
$r = mcp( 'create_form', { path => '/team.md', name => 'join' } );
ok( $r->{ok}, 'create_form on /team.md succeeds' );
my $team = slurp("$docroot/team.md");
like( $team, qr/The team\..*:::form/s, 'the .md spelling keeps the text too' );
like( $team, qr/^form: join$/m,        'and binds the form' );

# --- a page with text and no front matter ------------------------------------
spit( "$docroot/plain.md", "# Plain\n\nA page without front matter.\n" );
$r = mcp( 'create_form', { path => '/plain', name => 'ask' } );
ok( $r->{ok}, 'create_form on a page with no front matter succeeds' ) or diag explain $r;
my $plain = slurp("$docroot/plain.md");
like( $plain, qr/A page without front matter\.\n.*:::form/s, 'its text is kept, the block after it' );
like( $plain, qr/\A---\nform: ask\n---\n/, 'and front matter naming the form is added' );
$html = run_processor( $docroot, '/plain' );
like( $html, qr/without front matter/, 'the served page carries its text' );
like( $html, qr/<form/i,               'and renders the form' );

# --- a page bound to another form is left alone ------------------------------
my $other = "---\ntitle: O\nform: first\n---\n\nBody.\n";
spit( "$docroot/other.md", $other );
$r = mcp( 'create_form', { path => '/other', name => 'second' } );
ok( !$r->{ok}, 'a page binding a different form is refused' );
is( slurp("$docroot/other.md"), $other, 'and is unchanged' );

# --- a page that exists and cannot be read is never written -------------------
SKIP: {
    spit( "$docroot/locked.md", $ABOUT );
    chmod 0000, "$docroot/locked.md";
    skip 'running as a user who reads a mode-0 file', 2 if -r "$docroot/locked.md";
    $r = mcp( 'create_form', { path => '/locked', name => 'contact' } );
    chmod 0644, "$docroot/locked.md";
    ok( !$r->{ok}, 'a page the tool cannot read is refused' ) or diag explain $r;
    is( slurp("$docroot/locked.md"), $ABOUT, 'and is not replaced' );
}

# --- a page that does not exist is created, as before -------------------------
$r = mcp( 'create_form', { path => '/fresh', name => 'hello' } );
ok( $r->{ok}, 'create_form on a new path succeeds' );
like( slurp("$docroot/fresh.md"), qr/\A---\ntitle: Hello\nform: hello\n---\n\n:::form/, 'and scaffolds the page' );

done_testing();
