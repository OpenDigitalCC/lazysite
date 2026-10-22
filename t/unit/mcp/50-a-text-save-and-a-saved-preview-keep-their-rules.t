#!/usr/bin/perl
# SM1031 (ruled 2026-10-12, "Fix all three"; found working SM1030):
#
#   (a) A TEXT SAVE WRITES VALID UTF-8. A JSON body carrying the raw bytes of a
#       lone surrogate (ED A0 80) decodes to U+D800, and a page read through the
#       lax :utf8 layer keeps whatever bytes it held; action_save wrote either
#       through the lax :utf8 layer, putting bytes that are not UTF-8 on disk.
#       Q15h refuses such bytes on every RAW door (page_bytes_refusal); every
#       text door - control-API save, MCP write_file, replace_text, copy_file,
#       create_page, create_form - now refuses them the same way.
#   (b) A SAVED-PAGE preview_page IS NO VISIT. It wrote an access-log line, as a
#       visitor's request does; a draft preview never did.
#   (c) A SAVED-PAGE preview_page RENDERS UNDER THE OWNING DOMAIN. It inherited
#       the MCP request's Host, so a domain's page was shown in another site's
#       dress - preview_public_page has rendered under the owner since SM441,
#       and a draft preview always has.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use JSON::PP   qw(encode_json decode_json);
use IPC::Open3 qw(open3);
use File::Temp qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root env_passthrough site_tempdir run_child);

my $root = repo_root();
my $d    = site_tempdir();
my $logs = tempdir( CLEANUP => 1 );

sub spit {
    my ( $p, $t ) = @_;
    ( my $dir = $p ) =~ s{/[^/]+\z}{};
    make_path($dir);
    open my $fh, '>:raw', $p or die "$p: $!";
    print {$fh} $t;
    close $fh;
    return;
}

sub slurp {
    my ($p) = @_;
    open my $fh, '<:raw', $p or return undef;
    local $/;
    return scalar <$fh>;
}

my $layout = '<html><head><title>[% page_title %]</title>'
    . '<meta name="theme-assets" content="[% theme_assets %]"></head>'
    . '<body><main>[% content %]</main></body></html>';
spit( "$d/lazysite/layouts/default/layout.tt", $layout );
spit( "$d/lazysite/layouts/default/layout.json", encode_json( { default_theme => 'day' } ) );
for my $t (qw(day night)) {
    spit( "$d/lazysite/layouts/default/themes/$t/theme.json",
        encode_json( { name => $t, version => '1.0', layouts => ['default'] } ) );
}
spit( "$d/lazysite/lazysite.conf",
    "site_name: T\nmcp_enabled: true\nlayout: default\ntheme: day\n"
        . "alias_hosts: mine.test\nalias.mine.test.content_root: sites/mine\n"
        . "alias.mine.test.theme: night\n" );
spit( "$d/index.md",              "---\ntitle: Home\n---\nHome.\n" );
spit( "$d/404.md",                "---\ntitle: NF\n---\nNot found.\n" );
spit( "$d/about.md",              "---\ntitle: About\n---\nPRIMARY-ABOUT\n" );
spit( "$d/sites/mine/index.md",   "---\ntitle: Mine\n---\nMine.\n" );
spit( "$d/sites/mine/about.md",   "---\ntitle: Mine about\n---\nMINE-ABOUT\n" );
spit( "$d/notes.md",              "---\ntitle: Notes\n---\nkeep NOTES-MARKER here\n" );
spit( "$d/lazysite/forms/f.conf", "targets:\n" );

# A page put on disk by a door that writes no caller's bytes (git, SSH): an
# OVERLONG encoding of '/' (C0 AF), which no UTF-8 decoder accepts.
my $OVERLONG = "---\ntitle: Old\n---\nA \xC0\xAF B OLD-MARKER\n";
spit( "$d/legacy.md", $OVERLONG );

spit( "$d/users-stub.pl", <<'STUB' );
#!/usr/bin/perl
use strict; use warnings; use JSON::PP qw(encode_json);
print encode_json( { ok => 1, settings => { mcp => 1, manage_content => 1, manage_forms => 1 } } );
STUB
chmod 0755, "$d/users-stub.pl";

# One tools/call over the CGI. $raw: the request body as bytes, for a body no
# encoder would write. %env: extra request environment (the request's Host).
sub mcp {
    my ( $tool, $args, $raw, %env ) = @_;
    my $body = $raw // encode_json( { jsonrpc => '2.0', id => 1, method => 'tools/call',
            params => { name => $tool, arguments => $args } } );
    local %ENV = ( env_passthrough(),
        PATH                         => $ENV{PATH},
        DOCUMENT_ROOT                => $d,
        REQUEST_METHOD               => 'POST',
        CONTENT_LENGTH               => length $body,
        LAZYSITE_USERS_TOOL          => "$d/users-stub.pl",
        LAZYSITE_FORWARD_DIAGNOSTICS => 'off',
        HTTP_AUTHORIZATION           => 'Bearer op:lzs_tok',
        %env,
    );
    open my $e, '>>', "$logs/stderr.log" or die $!;
    my $resp = run_child( [ $^X, "$root/lazysite-mcp.pl" ], stdin => $body, stderr => $e )->{out};
    close $e;
    my ($jb) = ( $resp // '' ) =~ /\r?\n\r?\n(.*)/s;
    my $j = eval { decode_json( $jb // '' ) };
    return { ok => 0, error => 'NO JSON-RPC BODY' } unless ref $j eq 'HASH';
    return { ok => 0, rpc_code => $j->{error}{code}, error => "JSON-RPC error: $j->{error}{message}" }
        if $j->{error};
    return $j->{result}{structuredContent} || {};
}

# A tools/call whose JSON carries $bytes raw inside the string at $key.
sub raw_call {
    my ( $tool, $args, $key, $bytes ) = @_;
    my $json = encode_json( { jsonrpc => '2.0', id => 1, method => 'tools/call',
            params => { name => $tool, arguments => { %$args, $key => 'SLOT' } } } );
    ( my $esc = $bytes ) =~ s/\n/\\n/g;    # JSON-escaped, the raw bytes left raw
    $json                =~ s/"SLOT"/"$esc"/ or die 'no slot';
    return mcp( $tool, undef, $json );
}

sub refused_encoding {
    my ( $label, $r, $file, $before ) = @_;
    ok( !$r->{ok}, "$label: refused" ) or diag explain $r;
    is( $r->{kind}, 'page-encoding-refused', "$label: as the raw doors refuse it" );
    like( $r->{error} // '', qr/not (?:be )?valid UTF-8/, "$label: saying why" );
    is( slurp($file), $before, "$label: and nothing was written" );
}

my $SURROGATE = "A \xED\xA0\x80 B";        # U+D800 encoded laxly: not UTF-8
my $PAST_MAX  = "A \xF4\x90\x80\x80 B";    # U+110000: past the last code point

subtest '(a) THE CONTROL: a valid text save is written' => sub {
    my $r = mcp( write_file => { path => '/ok.md', content => "---\ntitle: OK\n---\ncaf\x{e9} \x{1F600}\n" } );
    ok( $r->{ok}, 'written' ) or diag explain $r;
    is( slurp("$d/ok.md"), "---\ntitle: OK\n---\ncaf\xC3\xA9 \xF0\x9F\x98\x80\n", 'as UTF-8' );
};

subtest '(a) write_file: a lone surrogate is refused' => sub {
    refused_encoding( 'new page',
        raw_call( write_file => { path => '/sur.md' }, content => "---\ntitle: S\n---\n$SURROGATE\n" ),
        "$d/sur.md", undef );
    refused_encoding( 'over an existing page',
        raw_call( write_file => { path => '/about.md' }, content => "---\ntitle: S\n---\n$SURROGATE\n" ),
        "$d/about.md", "---\ntitle: About\n---\nPRIMARY-ABOUT\n" );
    refused_encoding( 'a non-page text file',
        raw_call( write_file => { path => '/style.css' }, content => "/* $SURROGATE */\n" ),
        "$d/style.css", undef );
    refused_encoding( 'a code point past U+10FFFF',
        raw_call( write_file => { path => '/max.md' }, content => "---\ntitle: S\n---\n$PAST_MAX\n" ),
        "$d/max.md", undef );
};

subtest '(a) replace_text and create_page: a lone surrogate is refused' => sub {
    my $before = slurp("$d/notes.md");
    refused_encoding( 'replace_text',
        raw_call( replace_text => { path => '/notes.md', old => 'NOTES-MARKER' }, new => $SURROGATE ),
        "$d/notes.md", $before );
    refused_encoding( 'create_page',
        raw_call( create_page => { slug => 'cp', title => 'CP' }, body => $SURROGATE ),
        "$d/cp.md", undef );
};

subtest '(a) an overlong page read laxly is not written on by a text door' => sub {
    refused_encoding( 'copy_file of it',
        mcp( copy_file => { from => '/legacy.md', to => '/legacy-copy.md' } ),
        "$d/legacy-copy.md", undef );
    refused_encoding( 'replace_text in it',
        mcp( replace_text => { path => '/legacy.md', old => 'OLD-MARKER', new => 'NEW' } ),
        "$d/legacy.md", $OVERLONG );
};

subtest '(a) the control API save door refuses the same' => sub {
    require ManagerSession;
    my $ms = ManagerSession::new_site( root => $root );
    $ms->users( 'setup-sysop', '--user', 'ada' );
    my $md = $ms->docroot;
    # encode_json writes U+D800 as ED A0 80, the bytes a client sends.
    my $r = $ms->call( 'ada', 'save', query => 'action=save&path=/sur.md',
        body => { content => "---\ntitle: S\n---\nA \x{D800} B\n" } );
    is( $r->{kind}, 'page-encoding-refused', 'a lone surrogate is refused' ) or diag explain $r;
    ok( !-e "$md/sur.md", 'and not written' );
    $r = $ms->call( 'ada', 'save', query => 'action=save&path=/ok.md',
        body => { content => "---\ntitle: OK\n---\nfine\n" } );
    ok( $r->{ok}, 'a valid save is written' ) or diag explain $r;
};

sub visits {
    my $n = 0;
    for my $f ( glob "$d/lazysite/logs/access-*.jsonl" ) {
        open my $fh, '<', $f or next;
        $n++ while <$fh>;
        close $fh;
    }
    return $n;
}

sub theme_of {
    my ($html) = @_;
    my ($t) = ( $html // '' ) =~ m{name="theme-assets" content="/lazysite-assets/default/([^"]+)"};
    return $t // '(none)';
}

subtest '(b) a saved-page preview writes no access-log visit' => sub {
    my $n = visits();
    my $r = mcp( preview_page => { path => '/about' } );
    ok( $r->{ok}, 'rendered' ) or diag explain $r;
    like( $r->{html} // '', qr/PRIMARY-ABOUT/, 'the saved page' );
    is( visits(), $n, 'and the access log is as it was' );
    my $dr = mcp( preview_page => { path => '/about', content => "---\ntitle: D\n---\nDRAFT\n" } );
    ok( $dr->{ok}, 'a draft preview renders too' );
    is( visits(), $n, 'and writes no visit either, as before' );
};

subtest '(c) a saved-page preview renders under the owning domain' => sub {
    my $r = mcp( preview_page => { path => '/sites/mine/about' } );
    ok( $r->{ok}, 'rendered' ) or diag explain $r;
    like( $r->{html} // '', qr/MINE-ABOUT/, 'the domain\'s page' );
    is( theme_of( $r->{html} ), 'night',     'in the domain\'s own theme' );
    is( $r->{rendered_as_host}, 'mine.test', 'and says which Host' );

    my $p = mcp( preview_page => { path => '/about' }, undef, HTTP_HOST => 'mine.test' );
    ok( $p->{ok}, 'a primary page asked over a domain\'s Host renders' ) or diag explain $p;
    like( $p->{html} // '', qr/PRIMARY-ABOUT/, 'as the primary\'s page' );
    is( theme_of( $p->{html} ), 'day', 'in the primary\'s theme, not the request Host\'s' );
    ok( !exists $p->{rendered_as_host}, 'and names no domain' );
};

done_testing();
