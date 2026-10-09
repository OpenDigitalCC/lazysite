#!/usr/bin/perl
# SM976 Q15h (ruled 2026-10-09, "Refuse + walker skips"): MCP's walks over every
# page's front matter - list_pages, audit_site, and form_list through the form
# rule's walk - leave out a page whose reading dies, and log it.
#
# Measured before (tmp/q15h-walkers-probe.before.out): one page whose bytes are
# not UTF-8, put there by git or SSH, made each of the three answer "Tool
# error" for the whole site.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use JSON::PP   qw(encode_json decode_json);
use IPC::Open3 qw(open3);
use Symbol     qw(gensym);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root env_passthrough site_tempdir);

my $root = repo_root();
my $d    = site_tempdir();
make_path( "$d/lazysite/auth", "$d/lazysite/forms", "$d/blog" );
sub spit { my ( $p, $t ) = @_; open my $fh, '>:raw', $p or die "$p: $!"; print {$fh} $t; close $fh; return }
spit( "$d/lazysite/lazysite.conf", "site_name: T\nmcp_enabled: true\n" );
spit( "$d/index.md",               "---\ntitle: Home\n---\nHome.\n" );
spit( "$d/blog/a.md",              "---\ntitle: A\nform: leads\n---\nA\n" );
spit( "$d/blog/bad.md", "---\ntitle: B\nform:\xFF leads\nregister:\n  - sitemap.xml\n---\nB\n" ); # as git or SSH would
spit( "$d/lazysite/forms/leads.conf", "targets:\n" );
my $stub = "$d/users-stub.pl";
spit( $stub, "#!/usr/bin/perl\nuse JSON::PP qw(encode_json);\n"
        . "print encode_json({ ok => 1, settings => { manage_content => 1, manage_forms => 1, "
        . "read_submissions => 1, api => 1, mcp => 1 } });\n" );
chmod 0755, $stub;

# One call: the tool's answer and what the process logged.
sub mcp {
    my ( $tool, $args ) = @_;
    my $body = encode_json( { jsonrpc => '2.0', id => 1, method => 'tools/call',
            params => { name => $tool, arguments => $args } } );
    local %ENV = ( env_passthrough(),
        DOCUMENT_ROOT                => $d,
        REQUEST_METHOD               => 'POST',
        CONTENT_LENGTH               => length $body,
        LAZYSITE_USERS_TOOL          => $stub,
        LAZYSITE_FORWARD_DIAGNOSTICS => 'off',
        LAZYSITE_LOG_LEVEL           => 'INFO',
        HTTP_AUTHORIZATION           => 'Bearer tester:lzs_tok',
    );
    my $log = "$d/stderr.log";
    open my $e, '>', $log or die $!;
    my $pid = open3( my $in, my $out, '>&' . fileno($e), $^X, "$root/lazysite-mcp.pl" );
    print {$in} $body;
    close $in;
    my $resp = do { local $/; <$out> };
    close $out;
    waitpid $pid, 0;
    close $e;
    open my $lf, '<', $log or die $!;
    my $text = do { local $/; <$lf> };
    my ($jb) = ( $resp // '' ) =~ /\r?\n\r?\n(.*)/s;
    my $j    = eval { decode_json( $jb // '' ) } || {};
    return ( ( $j->{error} ? { ok => 0, error => $j->{error}{message} } : $j->{result}{structuredContent} || {} ), $text );
}

subtest 'list_pages' => sub {
    my ( $r, $log ) = mcp( 'list_pages', {} );
    ok( $r->{ok}, 'answers' ) or diag explain $r;
    is_deeply( [ map { $_->{path} } @{ $r->{pages} || [] } ], [ '/blog/a.md', '/index.md' ], 'with every readable page' );
    like( $log, qr/\[WARN\].*\[list_pages\] a page that cannot be read is left out/, 'the page left out is logged' );
    like( $log, qr{page=blog/bad\.md}, '...by its path' );
};

subtest 'audit_site' => sub {
    my ( $r, $log ) = mcp( 'audit_site', {} );
    ok( $r->{ok}, 'answers' ) or diag explain $r;
    like( $log, qr/\[WARN\].*\[audit_site\] a page that cannot be read is left out.*page=blog\/bad\.md|page=blog\/bad\.md.*\[audit_site\]/,
        'the page left out is logged' );
};

subtest 'form_list, through the form rule\'s walk' => sub {
    my ( $r, $log ) = mcp( 'form_list', {} );
    ok( $r->{ok}, 'answers' ) or diag explain $r;
    is_deeply( [ map { $_->{name} } @{ $r->{forms} || [] } ], ['leads'], 'with the form the readable page binds' );
    like( $log, qr/\[form-rule\] a page whose front matter cannot be read binds no form/, 'the page is logged' );
};

done_testing();
