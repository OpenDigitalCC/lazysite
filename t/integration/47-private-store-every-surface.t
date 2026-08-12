#!/usr/bin/perl
# SM286 step 1: every surface resolves the private store, and a write inside a
# gated section stays inside it.
#
# Shaped as a matrix for the same reason t/integration/44 was: the defect this
# programme keeps meeting is surfaces disagreeing about one question, and each
# channel tested against itself never finds it. Here the question is "where does
# this content live", asked of the manager, MCP and WebDAV.
#
# Nothing is moved by the product yet. The fixture places files in the private
# tree by hand, which is exactly how the move will find a surface that was
# forgotten.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use JSON::PP   qw(encode_json decode_json);
use IPC::Open2;
use MIME::Base64 ();
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper        qw(repo_root run_script setup_dav_site grant_caps);
use Lazysite::Private qw(private_path private_root);

my $root = repo_root();

sub spit {
    my ( $p, $t ) = @_;
    make_path( $p =~ s{/[^/]+\z}{}r );
    open my $fh, '>', $p or die "$p: $!";
    print {$fh} $t;
    close $fh;
    return;
}

my $site = setup_dav_site( user => 'partner', password => 'secret' );
my $d    = $site->{docroot};
make_path("$d/lazysite/manager/locks");
grant_caps( $d, 'boss', qw(ui manage_users) );

open my $cf, '>>', "$d/lazysite/lazysite.conf" or die $!;
print {$cf} "mcp_enabled: true\ncontrol_api_enabled: true\n";
close $cf;

# A gated section that has already been moved out, as the move will leave it.
spit( private_path( $d, 'upcoming/secret.md' ), "---\ntitle: S\n---\nPRIVATEBYTES\n" );
spit( "$d/lazysite/auth/acls.json", encode_json( { upcoming => { read => ['partner'] } } ) );

my $stub = "$d/users-stub.pl";
spit( $stub, <<'STUB' );
#!/usr/bin/perl
use strict; use warnings; use JSON::PP qw(encode_json);
my $in = do { local $/; <STDIN> };
print encode_json({ ok => 1, settings => {
    webdav => 1, manage_content => 1, mcp => 1, api => 1,
} });
STUB
chmod 0755, $stub;

# --- reading it, on each surface --------------------------------------------

sub read_via_dav {
    my ($path) = @_;
    local %ENV = %ENV;
    $ENV{DOCUMENT_ROOT}           = $d;
    $ENV{SCRIPT_NAME}             = '/dav';
    $ENV{REMOTE_ADDR}             = '127.0.0.1';
    $ENV{LAZYSITE_DAV_FAIL_DELAY} = 0;
    $ENV{LAZYSITE_USERS_TOOL}     = $stub;
    $ENV{HTTP_AUTHORIZATION}
        = 'Basic ' . MIME::Base64::encode_base64( 'partner:secret', '' );
    $ENV{REQUEST_METHOD} = 'GET';
    $ENV{PATH_INFO}      = $path;
    $ENV{CONTENT_LENGTH} = 0;
    return scalar `\Q$^X\E \Q$root/lazysite-dav.pl\E </dev/null 2>/dev/null`;
}

sub mcp_call {
    my ( $tool, $args ) = @_;
    my $body = encode_json(
        { jsonrpc => '2.0', id => 1, method => 'tools/call',
            params => { name => $tool, arguments => $args },
        }
    );
    local %ENV = %ENV;
    $ENV{DOCUMENT_ROOT}       = $d;
    $ENV{REQUEST_METHOD}      = 'POST';
    $ENV{CONTENT_LENGTH}      = length $body;
    $ENV{LAZYSITE_USERS_TOOL} = $stub;
    $ENV{HTTP_AUTHORIZATION}  = 'Bearer partner:lzs_x';
    my ( $out, $in );
    my $pid = open2( $out, $in, $^X, "$root/lazysite-mcp.pl" );
    print {$in} $body;
    close $in;
    my $resp = do { local $/; <$out> };
    close $out;
    waitpid $pid, 0;
    return $resp // '';
}

subtest 'WebDAV reads content from the private store' => sub {
    my $out = read_via_dav('/upcoming/secret.md');
    like( $out, qr/PRIVATEBYTES/,
        'the partner, who the ACL admits, is served the private copy' );
};

subtest 'MCP reads it too' => sub {
    my $out = mcp_call( 'read_file', { path => '/upcoming/secret.md' } );
    like( $out, qr/PRIVATEBYTES/, 'read_file resolves the private store' );
};

subtest 'and the manager lists the section from it' => sub {
    my $out = mcp_call( 'list_files', { path => '/upcoming' } );
    like( $out, qr/secret\.md/,
        'the listing shows content that is not in the docroot at all' );
};

# --- the write rule, which is the one with teeth ----------------------------
# A save into a gated section must land in the private tree. If it landed in the
# docroot it would create a public folder for a section that was moved out, and
# half-publish it through an operation nobody thinks of as a permission change.
subtest 'a new file written into a gated section stays private' => sub {
    my $out = mcp_call( 'write_file',
        { path => '/upcoming/added.md', content => "---\ntitle: A\n---\nNEW\n" } );
    unlike( $out, qr/"error"/, 'the write succeeds' ) or diag $out;

    ok( -e private_path( $d, 'upcoming/added.md' ),
        'the new file is in the PRIVATE store, beside the section it joined' );
    ok( !-e "$d/upcoming/added.md",
        'and NOT in the docroot' );
    ok( !-d "$d/upcoming",
        'no public folder was created for the gated section - which is the '
            . 'half-publish this rule exists to prevent' );
};

subtest 'a WebDAV PUT into the same section behaves identically' => sub {
    my $body = "---\ntitle: D\n---\nDAVNEW\n";
    my $bf   = tempdir( CLEANUP => 1 ) . '/b';
    spit( $bf, $body );
    local %ENV = %ENV;
    $ENV{DOCUMENT_ROOT}           = $d;
    $ENV{SCRIPT_NAME}             = '/dav';
    $ENV{REMOTE_ADDR}             = '127.0.0.1';
    $ENV{LAZYSITE_DAV_FAIL_DELAY} = 0;
    $ENV{LAZYSITE_USERS_TOOL}     = $stub;
    $ENV{HTTP_AUTHORIZATION}
        = 'Basic ' . MIME::Base64::encode_base64( 'partner:secret', '' );
    $ENV{REQUEST_METHOD} = 'PUT';
    $ENV{PATH_INFO}      = '/upcoming/dav.md';
    $ENV{CONTENT_LENGTH} = length $body;
    my $out = `\Q$^X\E \Q$root/lazysite-dav.pl\E <\Q$bf\E 2>/dev/null`;
    like( $out, qr/Status: 2\d\d/, "the PUT succeeds" ) or diag $out;

    ok( -e private_path( $d, 'upcoming/dav.md' ), 'and lands in the private store' );
    ok( !-e "$d/upcoming/dav.md",                 'not in the docroot' );
};

# --- public content is untouched --------------------------------------------
subtest 'an ordinary write still goes to the docroot' => sub {
    my $out = mcp_call( 'write_file',
        { path => '/ordinary.md', content => "---\ntitle: O\n---\nPUBLIC\n" } );
    unlike( $out, qr/"error"/, 'the write succeeds' ) or diag $out;
    ok( -e "$d/ordinary.md", 'a path with no private ancestor is public' );
    ok( !-e private_path( $d, 'ordinary.md' ),
        'and nothing was created in the private store' );
};

done_testing();
