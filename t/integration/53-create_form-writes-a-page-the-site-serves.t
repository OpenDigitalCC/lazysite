#!/usr/bin/perl
# SM655: `create_form` saved the caller's path verbatim, so the idiomatic call
# wrote an extensionless file and the form shipped dead.
#
# `create_form {"path": "/thing"}` produced a file named `thing` with no
# extension. THREE separate checks reported success - ok:true, page_status
# exists:true, and read_file returning valid page source with the front matter
# and the :::form block - and the public URL returned 404. delete_page could
# not remove it either ("File not found"); only delete_file could.
#
# Extensionless page paths are the idiom everywhere else on this surface
# (read_page "/about", page_status "/about"), and create_form's own schema
# describes the argument as "Page to add the form to (created if absent)". So
# an agent following the surface's own conventions got a dead form, and an
# agent that happened to pass ".md" got a working one, with nothing anywhere
# explaining the difference.
#
# THE ASSERTION HAS TO BE THE PUBLIC FETCH. Everything cheaper than that
# reported success while the page 404'd, which is precisely why this went
# unnoticed - so a test that checks ok:true, or the file's existence, would
# have passed against the defect.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP   qw(encode_json decode_json);
use IPC::Open2;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root env_passthrough run_processor);

my $root    = repo_root();
my $docroot = tempdir( CLEANUP => 1 );
make_path("$docroot/lazysite/auth");
open my $cf, '>', "$docroot/lazysite/lazysite.conf" or die $!;
print {$cf} "site_name: T\nmcp_enabled: true\n";
close $cf;

my $stub = "$docroot/users-stub.pl";
open my $sf, '>', $stub or die $!;
print {$sf} "#!/usr/bin/perl\nuse JSON::PP qw(encode_json);\n"
    . "print encode_json({ ok => 1, settings => { manage_content => 1, "
    . "manage_forms => 1, api => 1, mcp => 1 } });\n";
close $sf;
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
    my ( $out, $in );
    my $pid = open2( $out, $in, $^X, "$root/lazysite-mcp.pl" );
    print {$in} $body;
    close $in;
    my $resp = do { local $/; <$out> };
    close $out;
    waitpid $pid, 0;
    my ($jb) = $resp =~ /\r?\n\r?\n(.*)/s;
    my $d    = eval { decode_json($jb) } || {};
    return eval { decode_json( $d->{result}{content}[0]{text} // '' ) } || {};
}

# THE IDIOMATIC CALL: an extensionless page path, as every other tool takes.
my $r = mcp( 'create_form',
    { path => '/zz-formflow', name => 'zz_formflow',
        fields => [ { name => 'email', type => 'email', label => 'Email' } ] } );
ok( $r->{ok}, 'create_form reports success' ) or diag explain $r;

# The cheap checks that all passed against the defect, kept so this test says
# plainly that they prove nothing on their own.
ok( -f "$docroot/zz-formflow.md", 'a .md file was written' )
    or diag( 'wrote: ' . join( ', ', glob("$docroot/zz-*") ) );
ok( !-e "$docroot/zz-formflow",
    'and NOT an extensionless file beside it - which is what shipped dead' );

# THE ONE THAT MATTERS.
my $page = run_processor( $docroot, '/zz-formflow' );
unlike( $page, qr/^Status: 404/m,
    'the public URL does not 404 - the form the tool created is actually served' )
    or diag('this is the defect: three checks said success and the page was gone');
like( $page, qr/form|input/i, 'and the rendered page carries the form' );

# The reply names the page that exists, not the one it was handed: a caller
# echoing this back, or fetching it, should not be sent somewhere else.
is( $r->{path}, '/zz-formflow', 'the reply names the resolved page path' );

# --- the .md spelling still works, and lands in the SAME place ---------------
# It was the workaround. It must not now produce a second file.
my $r2 = mcp( 'create_form',
    { path => '/zz-explicit.md', name => 'zz_explicit',
        fields => [ { name => 'email', type => 'email', label => 'Email' } ] } );
ok( $r2->{ok}, 'an explicit .md path is still accepted' );
ok( -f "$docroot/zz-explicit.md", 'and writes the same shape' );
ok( !-e "$docroot/zz-explicit.md.md", 'not doubled' );

# THE REPLY IS CHECKED HERE, not on the call above, because there the input
# and the resolved path are the same string - so the assertion passed whether
# the reply echoed the argument or reported the resolution. This input is the
# one where they differ.
is( $r2->{path}, '/zz-explicit',
    'the reply reports the page that exists, not the argument it was handed' );
my $p2 = run_processor( $docroot, '/zz-explicit' );
unlike( $p2, qr/^Status: 404/m, 'and that page is served' );

done_testing();
