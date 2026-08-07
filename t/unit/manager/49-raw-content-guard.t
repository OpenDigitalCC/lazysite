#!/usr/bin/perl
# SM189: the write path refuses a content page that ships script-capable RAW
# output (api:/raw: front matter + a script-capable content_type). It bypasses
# the layout/theme, is served as plain text (ADR 0006), and evades the no-CDN
# guard. Covers the shared helper and the action_save wiring (which the manager
# save AND MCP write_file/create_page both route through). The WebDAV PUT path is
# covered in the dav suite.
use strict;
use warnings;
use Test::More;
use FindBin;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);

my $root = repo_root();

BEGIN {
    $ENV{LAZYSITE_API_LOAD_ONLY} = 1;
    $ENV{DOCUMENT_ROOT}          = '/tmp';
}
{
    package main;
    do "$root/lazysite-manager-api.pl" or die "load failed: $@";
}

use Lazysite::Manager::Common qw(raw_html_page_refusal);

# --- the helper: refuse script-capable raw pages, allow everything else -------
subtest 'raw_html_page_refusal condition' => sub {
    ok( raw_html_page_refusal("---\ntitle: X\napi: true\ncontent_type: text/html; charset=utf-8\n---\n<!DOCTYPE html>"),
        'api:true + text/html -> refused' );
    ok( raw_html_page_refusal("---\nraw: true\ncontent_type: image/svg+xml\n---\n<svg>"),
        'raw:true + svg -> refused' );
    ok( raw_html_page_refusal("---\napi: true\ncontent_type: application/xhtml+xml\n---\n<html>"),
        'api:true + xhtml -> refused' );

    ok( !raw_html_page_refusal("---\ntitle: X\napi: true\ncontent_type: application/json\n---\n{}"),
        'api:true + application/json (a real artifact) -> allowed' );
    ok( !raw_html_page_refusal("---\ntitle: X\n---\n# hello"),
        'plain Markdown page -> allowed' );
    ok( !raw_html_page_refusal("---\ntitle: X\ncontent_type: text/html\n---\n<b>x</b>"),
        'content_type without api/raw (not served raw) -> allowed' );
    ok( !raw_html_page_refusal("no front matter at all\n<html>"),
        'no front matter -> allowed' );
    ok( !raw_html_page_refusal(undef), 'undef -> allowed (no content)' );
};

# SM228: the refusal must name the ALTERNATIVE, not only the prohibition. The
# reader is usually someone who wants a self-contained HTML file served
# unchanged, and `raw:` is the key whose name invites exactly that - so the
# message has to point at the static-file route, which is a different mechanism.
subtest 'the refusal names the static-file alternative' => sub {
    my $msg = raw_html_page_refusal(
        "---\ntitle: X\napi: true\ncontent_type: text/html\n---\n<!DOCTYPE html>" );
    like( $msg, qr/static file/i, 'names the static-file route' );
    like( $msg, qr/byte-for-byte/i, 'and says a static file is served unchanged' );
    like( $msg, qr/\.html/, 'and names the extension to use' );
    like( $msg, qr/ADR 0006/, 'still cites the decision it enforces' );
};

# --- action_save wiring (manager save + MCP write_file/create_page) -----------
subtest 'action_save refuses a raw HTML content page' => sub {
    my $docroot = tempdir( CLEANUP => 1 );
    make_path("$docroot/lazysite/auth");
    no warnings 'once';
    $Lazysite::Manager::Common::DOCROOT = $docroot;
    $Lazysite::Manager::Files::DOCROOT  = $docroot;

    my $evil = "---\ntitle: UNITED\napi: true\ncontent_type: text/html; charset=utf-8\n---\n"
        . qq{<!DOCTYPE html><html><head><link href="https://fonts.googleapis.com/x"></head></html>};
    my $r = Lazysite::Manager::Files::action_save( '/index.md', 'agent', $evil, undef );
    is( $r->{ok},   0,                    'raw HTML index.md is refused' );
    is( $r->{kind}, 'raw-content-refused', 'refusal carries the kind' );
    ok( !-e "$docroot/index.md", 'nothing written to disk' );

    my $ok = Lazysite::Manager::Files::action_save(
        '/index.md', 'agent', "---\ntitle: Home\n---\n# Welcome\n", undef );
    ok( $ok->{ok}, 'a normal Markdown page still saves' );
    ok( -f "$docroot/index.md", 'the Markdown page is written' );

    my $art = Lazysite::Manager::Files::action_save(
        '/data.json', 'agent', "---\napi: true\ncontent_type: application/json\n---\n{}\n", undef );
    ok( $art->{ok}, 'a genuine JSON artifact (non-script type) still saves' );
};

done_testing();
