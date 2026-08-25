#!/usr/bin/perl
# SM556: a symlinked docroot is one docroot.
#
# Every manager module confines a target by comparing realpath($target)
# against the $DOCROOT the dispatcher handed it, assuming that docroot is
# canonical. Neither dispatcher made it so. Under a symlinked DOCUMENT_ROOT
# three modules refused (Themes delete and cache invalidate, Plugins
# submissions - "Invalid theme path", blocked, "Invalid submissions file") and
# two succeeded (Layouts delete, Domains purge), because the latter resolve
# both sides (tmp/tl-probe-symlink-docroot.pl).
#
# The fix is at the two dispatchers, once: Lazysite::Paths::canonical_docroot.
# It resolves the docroot only when both spellings find the same engine tree
# (an unmigrated site), so a site whose -lazysite tree is found by one
# spelling only keeps that spelling.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP   qw(encode_json decode_json);
use IPC::Open2;
use FindBin;
use lib "$FindBin::Bin/../../../lib";
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);

my $root = repo_root();
my $base = tempdir( CLEANUP => 1 );
my $real = "$base/real-site";
my $doc  = "$base/site";              # symlink -> real-site

sub _w {
    my ( $p, $c ) = @_;
    open my $f, '>', $p or die "$p: $!";
    print {$f} $c;
    close $f;
    return;
}

make_path("$real/lazysite/layouts/l/themes/$_") for qw(victim active);
make_path("$real/lazysite/layouts/old");
make_path( "$real/lazysite/forms/submissions", "$real/lazysite/manager/locks",
    "$real/lazysite/auth" );
symlink $real, $doc or die "symlink: $!";
_w( "$doc/lazysite/lazysite.conf",
    "layout: l\ntheme: active\nmcp_enabled: true\n" );
_w( "$doc/lazysite/layouts/l/layout.tt",   "[% content %]" );
_w( "$doc/lazysite/layouts/old/layout.tt", "[% content %]" );
_w( "$doc/lazysite/layouts/l/themes/victim/theme.json",
    '{"name":"victim","layouts":["l"]}' );
_w( "$doc/lazysite/layouts/l/themes/active/theme.json",
    '{"name":"active","layouts":["l"]}' );
_w( "$doc/page.md",                                  "# p\n" );
_w( "$doc/page.html",                                "<html>p</html>" );
_w( "$doc/lazysite/forms/submissions/contact.jsonl", qq({"name":"x"}\n) );

# --- the control API, loaded as the dispatcher loads it -----------------------
BEGIN {
    $ENV{LAZYSITE_API_LOAD_ONLY} = 1;
    $ENV{DOCUMENT_ROOT}          = '/tmp';
}
{
    local $ENV{DOCUMENT_ROOT} = $doc;
    package main;
    do "$root/lazysite-manager-api.pl" or die "load failed: $@";
}

subtest 'the control API hands every module one canonical docroot' => sub {
    is( $Lazysite::Manager::Themes::DOCROOT, $real,
        'Themes sees the resolved tree' )
        or diag('The dispatcher passed DOCUMENT_ROOT as the web server spelled it.');
    is( $Lazysite::Manager::Plugins::DOCROOT, $real, 'so does Plugins' );
    is( $Lazysite::Manager::Common::DOCROOT,  $real, 'and Common' );
};

subtest 'the three actions that refused now succeed' => sub {
    my $td = main::action_theme_delete('victim');
    is( $td->{ok}, 1, 'Themes::action_theme_delete' ) or diag explain $td;
    my $ci = main::action_cache_invalidate('/page');
    is( $ci->{ok}, 1, 'Themes::action_cache_invalidate' ) or diag explain $ci;
    my $fs = main::action_form_submissions('lazysite/forms/submissions/contact.jsonl');
    is( $fs->{ok}, 1, 'Plugins::action_form_submissions' ) or diag explain $fs;
};

subtest 'the two that already succeeded still do' => sub {
    my $ld = main::action_layout_delete('old');
    is( $ld->{ok}, 1, 'Layouts::action_layout_delete' ) or diag explain $ld;
    ok( !-d "$real/lazysite/layouts/old", 'and the layout is gone from the real tree' );
};

# --- the MCP, run as a subprocess under the symlink ---------------------------
my $stub = "$base/users-stub.pl";
_w( $stub, <<'STUB' );
#!/usr/bin/perl
use strict; use warnings; use JSON::PP qw(encode_json);
my $in = do { local $/; <STDIN> };
print encode_json({ ok => 1, settings => { mcp => 1, webdav => 1, manage_content => 1 } });
STUB
chmod 0755, $stub;

sub _mcp_call {
    my ( $tool, $args ) = @_;
    my $body = encode_json( { jsonrpc => '2.0', id => 1, method => 'tools/call',
            params => { name => $tool, arguments => $args } } );
    local %ENV = %ENV;
    delete $ENV{LAZYSITE_API_LOAD_ONLY};
    $ENV{DOCUMENT_ROOT}       = $doc;
    $ENV{REQUEST_METHOD}      = 'POST';
    $ENV{CONTENT_LENGTH}      = length $body;
    $ENV{LAZYSITE_USERS_TOOL} = $stub;
    $ENV{HTTP_AUTHORIZATION}  = 'Bearer claude:lzs_tok';
    my ( $out, $in );
    my $pid = open2( $out, $in, $^X, "$root/lazysite-mcp.pl" );
    print {$in} $body;
    close $in;
    my $resp = do { local $/; <$out> };
    close $out;
    waitpid $pid, 0;
    my ($jb) = $resp =~ /\r?\n\r?\n(.*)/s;
    return ( defined $jb && length $jb ) ? eval { decode_json($jb) } : undef;
}

subtest 'the MCP confines against the same canonical docroot' => sub {
    _w( "$doc/page.html", "<html>p</html>" );
    my $r  = _mcp_call( 'invalidate_cache', { path => '/page' } );
    my $sc = $r->{result}{structuredContent};
    ok( $sc && $sc->{ok}, 'invalidate_cache on a symlinked docroot succeeds' )
        or diag explain $r;
    ok( !-e "$real/page.html", 'and the render is gone from the real tree' );
};

# --- the helper's own contract -----------------------------------------------
subtest 'canonicalising never moves the engine tree' => sub {
    require Lazysite::Paths;
    ok( Lazysite::Paths->can('canonical_docroot'), 'Paths::canonical_docroot exists' )
        or return;
    is( Lazysite::Paths::canonical_docroot($doc), $real,
        'an unmigrated site resolves: its tree is inside either spelling' );
    is( Lazysite::Paths::canonical_docroot("$doc/"), $real, 'a trailing slash too' );
    is( Lazysite::Paths::canonical_docroot($real),   $real, 'a real path is itself' );
    is( Lazysite::Paths::canonical_docroot('/nonexistent/docroot-zz'),
        '/nonexistent/docroot-zz', 'a docroot that does not exist is left as given' );

    # Migrated BESIDE THE SYMLINK: the tree is named for the symlink's spelling
    # and lives where only that spelling finds it. Resolving would send the
    # manager to $real/lazysite while the front end serves the outside copy.
    my $d2 = "$base/beside";
    my $r2 = "$base/beside-real";
    make_path("$r2");
    symlink $r2, $d2 or die $!;
    make_path("$d2-lazysite");
    is( Lazysite::Paths::canonical_docroot($d2), $d2,
        'a site whose -lazysite tree sits beside the symlink keeps that spelling' )
        or diag('Resolving here would move the engine tree out from under the front end.');

    # Migrated beside the REAL directory: the symlink spelling does not find
    # that tree at all (it looks beside the symlink, then inside), so the two
    # spellings disagree and the given one is kept - today's behaviour, and the
    # operator's arrangement to repair, never this helper's to guess at.
    my $d3 = "$base/besidereal";
    my $r3 = "$base/deep/besidereal-real";
    make_path( $r3, "$base/deep/besidereal-real-lazysite" );
    symlink $r3, $d3 or die $!;
    is( Lazysite::Paths::canonical_docroot($d3), $d3,
        'a tree found by one spelling only is left to that spelling' );
};

subtest 'both dispatchers canonicalise, once each' => sub {
    for my $cgi (qw(lazysite-manager-api.pl lazysite-mcp.pl)) {
        my $src = do {
            open my $fh, '<', "$root/$cgi" or die $!;
            local $/;
            <$fh>;
        };
        my @calls = $src =~ /Lazysite::Paths::canonical_docroot\(/g;
        is( scalar @calls, 1, "$cgi takes its docroot through canonical_docroot" );
    }
};

done_testing();
