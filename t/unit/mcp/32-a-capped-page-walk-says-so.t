#!/usr/bin/perl
# SM976 Q15j (ruled 2026-10-10, "Fix both" (b)): MCP's page walk (_each_page)
# stops at 1,000 pages, and every tool over it says so - `truncated: true` and
# `page_cap` - so a count is never silently capped.
#
# Before: list_pages answered count 1000 and audit_site pages 1000 on a site of
# 1,001 pages, each reading as the whole site, and rename_page's link rewrite
# left the links in the page past the cap unrewritten, reporting nothing.
# Asserted at the boundary: 1,000 pages is the whole site (truncated false),
# 1,001 is not (truncated true, the cap named, 1,000 walked).
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use JSON::PP   qw(encode_json decode_json);
use IPC::Open3 qw(open3);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root env_passthrough site_tempdir);

my $root = repo_root();
sub spit { my ( $p, $t ) = @_; open my $fh, '>:raw', $p or die "$p: $!"; print {$fh} $t; close $fh; return }

# A site of $n pages, each linking to /target (one more page, counted in $n).
sub site {
    my ($n) = @_;
    my $d = site_tempdir();
    make_path( "$d/lazysite/auth", "$d/p" );
    spit( "$d/lazysite/lazysite.conf", "site_name: T\nmcp_enabled: true\n" );
    spit( "$d/target.md",              "---\ntitle: Target\n---\nT\n" );
    spit( sprintf( "$d/p/%04d.md", $_ ), "---\ntitle: P$_\n---\nSee [t](/target).\n" ) for 1 .. $n - 1;
    my $stub = "$d/users-stub.pl";
    spit( $stub, "#!/usr/bin/perl\nuse JSON::PP qw(encode_json);\n"
            . "print encode_json({ ok => 1, settings => { manage_content => 1, api => 1, mcp => 1 } });\n" );
    chmod 0755, $stub;
    return $d;
}

sub mcp {
    my ( $d, $tool, $args ) = @_;
    my $body = encode_json( { jsonrpc => '2.0', id => 1, method => 'tools/call',
            params => { name => $tool, arguments => $args } } );
    local %ENV = ( env_passthrough(),
        DOCUMENT_ROOT                => $d,
        REQUEST_METHOD               => 'POST',
        CONTENT_LENGTH               => length $body,
        LAZYSITE_USERS_TOOL          => "$d/users-stub.pl",
        LAZYSITE_FORWARD_DIAGNOSTICS => 'off',
        HTTP_AUTHORIZATION           => 'Bearer tester:lzs_tok',
    );
    open my $e, '>', "$d/stderr.log" or die $!;
    my $pid = open3( my $in, my $out, '>&' . fileno($e), $^X, "$root/lazysite-mcp.pl" );
    print {$in} $body;
    close $in;
    my $resp = do { local $/; <$out> };
    close $out;
    waitpid $pid, 0;
    close $e;
    my ($jb) = ( $resp // '' ) =~ /\r?\n\r?\n(.*)/s;
    my $j    = eval { decode_json( $jb // '' ) } || {};
    return $j->{result}{structuredContent} || { ok => 0, error => 'no answer' };
}

subtest 'a site of exactly 1,000 pages is walked whole' => sub {
    my $d = site(1000);
    my $r = mcp( $d, list_pages => {} );
    is( $r->{count}, 1000, 'list_pages: count 1000' ) or diag explain { %$r, pages => undef };
    ok( exists $r->{truncated} && !$r->{truncated}, '...truncated false' );
    ok( !exists $r->{page_cap},                     '...and no cap named' );
    $r = mcp( $d, audit_site => {} );
    is( $r->{pages}, 1000, 'audit_site: pages 1000' );
    ok( exists $r->{truncated} && !$r->{truncated}, '...truncated false' );
    $r = mcp( $d, rename_page => { old => '/target', new => '/moved', update_links => JSON::PP::true } );
    ok( $r->{ok}, 'rename_page' ) or diag explain $r;
    is( $r->{links_updated}, 999, '...rewrote every page linking to it' );
    ok( exists $r->{truncated} && !$r->{truncated}, '...truncated false' );
};

subtest 'a site of 1,001 pages: each tool says it stopped at the cap' => sub {
    my $d = site(1001);
    my $r = mcp( $d, list_pages => {} );
    is( $r->{count}, 1000, 'list_pages: count covers the 1,000 walked' ) or diag explain { %$r, pages => undef };
    ok( $r->{truncated}, '...truncated true' );
    is( $r->{page_cap}, 1000, '...and the cap named' );
    $r = mcp( $d, audit_site => {} );
    is( $r->{pages}, 1000, 'audit_site: pages covers the 1,000 walked' );
    ok( $r->{truncated}, '...truncated true' );
    is( $r->{page_cap}, 1000, '...and the cap named' );
    $r = mcp( $d, rename_page => { old => '/target', new => '/moved', update_links => JSON::PP::true } );
    ok( $r->{ok},        'rename_page' ) or diag explain $r;
    ok( $r->{truncated}, '...truncated true: a page past the cap was not rewritten' );
    is( $r->{page_cap}, 1000, '...and the cap named' );
    my $left = grep {
        open my $fh, '<', $_ or die $!;
        local $/;
        <$fh> =~ m{\(/target\)};
    } glob("$d/p/*.md");
    cmp_ok( $left, '>', 0, '...which is so: a page still links to the old path' );
};

subtest 'rename_page without update_links walks nothing and says nothing of a cap' => sub {
    my $d = site(3);
    my $r = mcp( $d, rename_page => { old => '/target', new => '/moved' } );
    ok( $r->{ok},                'rename_page' ) or diag explain $r;
    ok( !exists $r->{truncated}, 'no truncated key' );
};

subtest 'the descriptions say so' => sub {
    open my $fh, '<', "$root/lazysite-mcp.pl" or die $!;
    my $src = do { local $/; <$fh> };
    for my $tool (qw(list_pages audit_site rename_page)) {
        my ($def) = $src =~ /^    \Q$tool\E => \{\n(.*?)\n    \},\n/ms;
        like( $def // '', qr/at most 1,000 pages.*"truncated".*"page_cap"/s, "$tool: its description names the cap and the keys" );
    }
};

done_testing();
