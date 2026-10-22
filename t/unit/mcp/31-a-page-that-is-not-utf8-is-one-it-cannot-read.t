#!/usr/bin/perl
# SM976 Q15j (ruled 2026-10-10, "Fix both" (a)): an MCP tool that reads ONE
# page answers a page whose bytes are not valid UTF-8 as a page it cannot read
# - an error naming the encoding problem, the first invalid byte's offset and
# how to fix it.
#
# Measured before (tmp/q15j-single-page-probe.before.out): read_page,
# read_file, view_version, read_brief and preview_page answered with no
# JSON-RPC body at all (the encoder died on the page's bytes); validate_page and
# create_form answered a bare "Tool error", and validate_page called a page
# with a bad byte in its front matter valid.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use JSON::PP   qw(encode_json decode_json);
use IPC::Open3 qw(open3);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper    qw(repo_root env_passthrough site_tempdir run_child);
use Lazysite::Git ();

my $root = repo_root();
my $d    = site_tempdir();
make_path( "$d/lazysite/auth", "$d/lazysite/briefs" );
sub spit { my ( $p, $t ) = @_; open my $fh, '>:raw', $p or die "$p: $!"; print {$fh} $t; close $fh; return }
spit( "$d/lazysite/lazysite.conf",
    "site_name: T\nmcp_enabled: true\ngit_history: enabled\nplugins:\n  - plugins/briefs.pl\n" );
spit( "$d/index.md", "---\ntitle: Home\n---\nHome caf\xC3\xA9.\n" );  # UTF-8: the control
spit( "$d/bad.md",   "---\ntitle: B\n---\nBody caf\xE9 here.\n" );    # offset 25
spit( "$d/badfm.md", "---\ntitle: B\xFF\n---\nBody.\n" );             # offset 12
spit( "$d/bad.txt",  "plain caf\xE9\n" );                             # offset 9
spit( "$d/hist.md",  "---\ntitle: H\n---\nold caf\xE9 text\n" );      # recorded bad (24)
spit( "$d/cur.md",   "---\ntitle: C\n---\nfine\n" );                  # recorded good
spit( "$d/lazysite/briefs/bad.md", "a brief caf\xE9\n" );             # offset 11

my $git = Lazysite::Git::git_available();
my ( $sha_hist, $sha_cur );
if ($git) {
    Lazysite::Git::init( $d, 'operator' )->{ok} or die 'history init failed';
    $sha_hist = Lazysite::Git::file_log( $d, 'hist.md' )->[0]{sha};
    $sha_cur  = Lazysite::Git::file_log( $d, 'cur.md' )->[0]{sha};
    spit( "$d/hist.md", "---\ntitle: H\n---\nnew text\n" );    # the current one is UTF-8
    spit( "$d/cur.md", "---\ntitle: C\n---\nnow caf\xE9 bad\n" ); # the current one is not (24)
}

my $stub = "$d/users-stub.pl";
spit( $stub, "#!/usr/bin/perl\nuse JSON::PP qw(encode_json);\n"
        . "print encode_json({ ok => 1, settings => { manage_content => 1, manage_forms => 1, "
        . "manage_briefs => 1, api => 1, mcp => 1 } });\n" );
chmod 0755, $stub;

# One call: the tool's answer, or what was wrong with the response. $SITE, when
# set, is the docroot instead of $d, and $SCRIPT the MCP script.
our ( $SITE, $SCRIPT );
sub mcp {
    my ( $tool, $args ) = @_;
    my $d    = $SITE // $d;
    my $body = encode_json( { jsonrpc => '2.0', id => 1, method => 'tools/call',
            params => { name => $tool, arguments => $args } } );
    local %ENV = ( env_passthrough(),
        PATH                         => $ENV{PATH},
        DOCUMENT_ROOT                => $d,
        REQUEST_METHOD               => 'POST',
        CONTENT_LENGTH               => length $body,
        LAZYSITE_USERS_TOOL          => "$d/users-stub.pl",
        LAZYSITE_FORWARD_DIAGNOSTICS => 'off',
        HTTP_AUTHORIZATION           => 'Bearer tester:lzs_tok',
    );
    open my $e, '>', "$d/stderr.log" or die $!;
    my $resp = run_child( [ $^X, $SCRIPT // "$root/lazysite-mcp.pl" ],
        stdin => $body, stderr => $e )->{out};
    close $e;
    my ($jb) = ( $resp // '' ) =~ /\r?\n\r?\n(.*)/s;
    my $j = eval { decode_json( $jb // '' ) };
    return { ok => 0, error => 'NO JSON-RPC BODY' } unless ref $j eq 'HASH';
    return { ok => 0, error => "JSON-RPC error: $j->{error}{message}" } if $j->{error};
    return $j->{result}{structuredContent} || {};
}

# The answer the ruling asks for.
sub cannot_read {
    my ( $r, $label, $at, $what ) = @_;
    $what //= qr/The (?:page|file)/;
    is( $r->{kind}, 'page-encoding-refused', "$label: refused as a page it cannot read" ) or diag explain $r;
    ok( !$r->{ok}, "$label: not ok" );
    like( $r->{error}, qr/$what '[^']+' is not valid UTF-8/, "$label: names the encoding problem" );
    like( $r->{error}, qr/first invalid byte is at offset $at\b/, "$label: and the offset ($at)" );
    like( $r->{error}, qr/To fix it, /, "$label: and how to fix it" );
    like( $r->{audit_detail}, qr/\Apage-encoding-refused: .* - \S/, "$label: audited as kind: cause - remedy" );
    return;
}

for my $c ( [ '/bad.md', 25 ], [ '/badfm.md', 12 ] ) {
    my ( $p, $at ) = @$c;
    subtest "single-page reads of $p" => sub {
        cannot_read( mcp( read_file           => { path => $p } ), 'read_file',     $at );
        cannot_read( mcp( read_page           => { path => $p } ), 'read_page',     $at );
        cannot_read( mcp( validate_page       => { path => $p } ), 'validate_page', $at );
        cannot_read( mcp( preview_page        => { path => $p } ), 'preview_page',  $at );
        cannot_read( mcp( preview_public_page => { path => $p } ), 'preview_public_page', $at );
        ( my $slug = $p ) =~ s/\.md\z//;
        cannot_read( mcp( create_form => { path => $slug, name => 'zz' } ), 'create_form', $at );
    };
}

subtest 'read_file of a text file that is not a page' => sub {
    my $r = mcp( read_file => { path => '/bad.txt' } );
    cannot_read( $r, 'read_file', 9, qr/The file/ );
};

subtest 'read_brief of a store entry that is not UTF-8' => sub {
    my $r = mcp( read_brief => { path => '/bad.md' } );
    cannot_read( $r, 'read_brief', 11, qr/The brief of the page/ );
    like( $r->{error}, qr{lazysite/briefs/bad\.md}, 'the remedy names the store entry' );
};

SKIP: {
    skip 'git not available', 2 unless $git;
    subtest 'view_version: a recorded version that is not UTF-8' => sub {
        my $r = mcp( view_version => { path => '/hist.md', version => $sha_hist } );
        cannot_read( $r, 'view_version', 24, qr/Version [0-9a-f]{7} of the page/ );
        like( $r->{error}, qr/list_versions/, 'the remedy points at another version' );
    };
    subtest 'view_version: a current file that is not UTF-8, which the diff carries' => sub {
        my $r = mcp( view_version => { path => '/cur.md', version => $sha_cur } );
        cannot_read( $r, 'view_version', 24, qr/The current version of the page/ );
        like( $r->{error}, qr/restore_version/, 'the remedy names restore_version' );
    };
}

# A UTF-8 page whose render is not UTF-8. No file the processor reads was found
# to do it (an include, nav.conf: the processor answers 500; a layout: TT puts
# U+FFFD in), so the processor beside the MCP script is a stub that prints such
# HTML - the answer must still be a body, naming the render.
subtest 'preview_page of a UTF-8 page whose render is not UTF-8' => sub {
    my $bin = site_tempdir();
    symlink( "$root/lib", "$bin/lib" ) or die "symlink: $!";
    spit( "$bin/lazysite-mcp.pl", do { open my $s, '<:raw', "$root/lazysite-mcp.pl" or die $!; local $/; <$s> } );
    spit( "$bin/lazysite-processor.pl",
        qq{binmode STDOUT; print "Status: 200 OK\r\nContent-Type: text/html\r\n\r\n<p>caf\xE9</p>\n";\n} );
    local $SCRIPT = "$bin/lazysite-mcp.pl";
    my $r = mcp( preview_page => { path => '/index' } );
    cannot_read( $r, 'preview_page', 6, qr/The rendered HTML of the page/ );
    like( $r->{error}, qr/the file the page renders with/, 'the remedy points at what the page renders with' );
};

# Every refusal the read makes first still answers first.
subtest 'a missing page and a blocked path answer as before' => sub {
    my $r = mcp( read_page => { path => '/nope.md' } );
    is( $r->{kind}, 'not-found', 'missing: not-found' ) or diag explain $r;
    $r = mcp( read_file => { path => '/lazysite/auth/users' } );
    isnt( $r->{kind} // '', 'page-encoding-refused', 'blocked: refused for its own reason' );
};

subtest 'a UTF-8 page reads as before (the control)' => sub {
    my $r = mcp( read_page => { path => '/index.md' } );
    ok( $r->{ok}, 'read_page' ) or diag explain $r;
    like( $r->{body}, qr/Home caf\x{e9}\./, '...with its text decoded' );
    $r = mcp( read_file => { path => '/index.md' } );
    ok( $r->{ok}, 'read_file' ) or diag explain $r;
    $r = mcp( validate_page => { path => '/index.md' } );
    ok( $r->{ok}, 'validate_page' ) or diag explain $r;
    $r = mcp( preview_page => { path => '/index' } );
    ok( $r->{ok}, 'preview_page' ) or diag explain $r;
    like( $r->{html} // '', qr/caf\x{e9}/, '...with its text in the HTML' );
};

done_testing();
