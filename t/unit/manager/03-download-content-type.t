#!/usr/bin/perl
# SM019: unit tests for detect_content_type and is_editable_text.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);

BEGIN {
    $ENV{LAZYSITE_API_LOAD_ONLY} = 1;
    $ENV{DOCUMENT_ROOT}          = '/tmp';
}

my $root = repo_root();
{
    package main;
    do "$root/lazysite-manager-api.pl" or die "load failed: $@";
}

# --- detect_content_type ---

subtest 'known extensions map correctly' => sub {
    is( main::detect_content_type('a.md'),    'text/plain; charset=utf-8',       'md' );
    is( main::detect_content_type('a.html'),  'text/html; charset=utf-8',        'html' );
    is( main::detect_content_type('a.css'),   'text/css; charset=utf-8',         'css' );
    is( main::detect_content_type('a.png'),   'image/png',                       'png' );
    is( main::detect_content_type('a.pdf'),   'application/pdf',                 'pdf' );
    is( main::detect_content_type('a.zip'),   'application/zip',                 'zip' );
    is( main::detect_content_type('a.jsonl'), 'application/jsonl; charset=utf-8', 'jsonl' );
};

subtest 'unknown extension falls back to octet-stream' => sub {
    is( main::detect_content_type('a.xyz'),
        'application/octet-stream', 'xyz' );
    is( main::detect_content_type('binary.mystery'),
        'application/octet-stream', 'mystery' );
};

subtest 'case-insensitive' => sub {
    is( main::detect_content_type('Foo.PNG'),  'image/png', 'PNG' );
    is( main::detect_content_type('IMG.JpeG'), 'image/jpeg', 'JpeG' );
};

subtest 'no extension returns octet-stream' => sub {
    is( main::detect_content_type('README'),
        'application/octet-stream', 'no-extension' );
    is( main::detect_content_type(''),
        'application/octet-stream', 'empty path' );
};

# --- is_editable_text ---

subtest 'common text extensions are editable' => sub {
    for my $ext (qw(md txt html css js json yaml conf log pl pm)) {
        ok( main::is_editable_text("f.$ext"), ".$ext editable" );
    }
};

subtest 'binary extensions are not editable' => sub {
    for my $ext (qw(png pdf zip jpg jpeg gif webp ico)) {
        ok( !main::is_editable_text("f.$ext"), ".$ext not editable" );
    }
};

subtest 'unknown extension defaults to editable' => sub {
    # Conservative: a brand-new config-style extension should open in
    # the editor rather than force a download.
    ok( !main::is_editable_text('weird.xyz'), 'unknown extension NOT editable (explicit allowlist)' );
};

subtest 'no extension is editable' => sub {
    ok( main::is_editable_text('README'),    'no extension editable' );
    ok( main::is_editable_text('Makefile'),  'Makefile editable' );
};

subtest 'dotfiles treated as binary' => sub {
    # is_editable_text captures "htaccess" as the extension; not in
    # TEXT_EXTENSIONS, so .htaccess opens as binary - intentional.
    ok( !main::is_editable_text('.htaccess'),
        '.htaccess not editable in browser' );
};

done_testing();
