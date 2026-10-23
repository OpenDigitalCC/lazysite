#!/usr/bin/perl
# SM1290 (K-4): MCP preview_page RENDERS A PAGE IN A THEME THAT IS NOT ACTIVE.
#
# A designer making a theme for a site could preview it only locally,
# rebuilding the token block from theme.json by hand, because preview_page
# rendered with the active theme alone (lazysite.io, 2026-10-22). `theme` names
# an installed theme to render with instead.
#
# What this holds:
#   - the saved page and a draft render in the named theme, over the site's
#     theme and over a page's own `theme:` pin;
#   - it writes nothing: every file under the site is as it was, byte for byte;
#   - it needs manage_themes or manage_layouts as well as manage_content, the
#     capability preview-grant already asks to show a theme that is not active;
#   - a theme that is not installed, or not installed for the layout the page
#     renders with, is refused - and a refusal is all that gets written: its
#     audit row.
use strict;
use warnings;
use Test::More;
use File::Path  qw(make_path);
use File::Find  ();
use Digest::SHA qw(sha256_hex);
use JSON::PP    qw(encode_json decode_json);
use File::Temp  qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root env_passthrough site_tempdir run_child);

my $root = repo_root();
my $d    = site_tempdir();
( my $site = $d ) =~ s{/[^/]+\z}{};
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

spit( "$d/lazysite/layouts/default/layout.tt", '<html><head><title>[% page_title %]</title>'
        . '<meta name="theme-assets" content="[% theme_assets %]"></head><body><main>[% content %]</main></body></html>' );
spit( "$d/lazysite/layouts/alt/layout.tt", '<html><body>[% content %]</body></html>' );
for my $t (qw(day night)) {
    spit( "$d/lazysite/layouts/default/themes/$t/theme.json",
        encode_json( { name => $t, version => '1.0', layouts => ['default'] } ) );
}
# Installed - but for another layout only.
spit( "$d/lazysite/layouts/alt/themes/elsewhere/theme.json",
    encode_json( { name => 'elsewhere', version => '1.0', layouts => ['alt'] } ) );
spit( "$d/lazysite/lazysite.conf", "site_name: T\nmcp_enabled: true\nlayout: default\ntheme: day\n" );
spit( "$d/index.md",  "---\ntitle: Home\n---\nHome.\n" );
spit( "$d/404.md",    "---\ntitle: NF\n---\nNot found.\n" );
spit( "$d/about.md",  "---\ntitle: About\n---\nThe SAVED about page.\n" );
spit( "$d/pinned.md", "---\ntitle: Pinned\ntheme: day\n---\nPinned to day.\n" );

# `themer` holds manage_themes as well; `writer` only content.
spit( "$d/users-stub.pl", <<'STUB' );
#!/usr/bin/perl
use strict; use warnings; use JSON::PP qw(encode_json decode_json);
my $in = do { local $/; <STDIN> };
my $r  = eval { decode_json($in) } || {};
my %s  = ( mcp => 1, manage_content => 1 );
$s{manage_themes} = 1 if ( $r->{username} // '' ) eq 'themer';
print encode_json( { ok => 1, settings => \%s } );
STUB
chmod 0755, "$d/users-stub.pl";

sub mcp {
    my ( $user, $tool, $args ) = @_;
    my $body = encode_json( { jsonrpc => '2.0', id => 1, method => 'tools/call',
            params => { name => $tool, arguments => $args } } );
    local %ENV = ( env_passthrough(),
        PATH                         => $ENV{PATH},
        DOCUMENT_ROOT                => $d,
        REQUEST_METHOD               => 'POST',
        CONTENT_LENGTH               => length $body,
        LAZYSITE_USERS_TOOL          => "$d/users-stub.pl",
        LAZYSITE_FORWARD_DIAGNOSTICS => 'off',
        HTTP_AUTHORIZATION           => "Bearer $user:lzs_tok",
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

sub snapshot {
    my %s;
    File::Find::find(
        { no_chdir => 1,
            wanted => sub {
                my $p = $File::Find::name;
                ( my $rel = $p ) =~ s{\A\Q$site\E/?}{};
                if ( -l $p ) { $s{$rel} = 'link:' . readlink $p; return }
                if ( -d $p ) { $s{$rel} = 'dir';                 return }
                open my $fh, '<:raw', $p or do { $s{$rel} = "unreadable"; return };
                my $c = do { local $/; <$fh> };
                close $fh;
                my @st = stat $p;
                $s{$rel} = sprintf '%o:%d:%d:%s', $st[2], $st[7], $st[9], sha256_hex($c);
            },
        },
        $site
    );
    return \%s;
}

sub changes {
    my ( $a, $b ) = @_;
    my %k = map { $_ => 1 } keys %$a, keys %$b;
    return [ map {
            !exists $a->{$_}       ? "added $_"
                : !exists $b->{$_} ? "removed $_"
                : "changed $_"
    } grep { ( $a->{$_} // '' ) ne ( $b->{$_} // '' ) } sort keys %k ];
}

sub theme_of { my ($html) = @_; my ($t) = ( $html // '' ) =~ m{name="theme-assets" content="/lazysite-assets/default/([^"]+)"}; return $t // '(none)' }

my $before = snapshot();

subtest 'the saved page renders in the named theme' => sub {
    my $r = mcp( themer => preview_page => { path => '/about', theme => 'night' } );
    ok( $r->{ok}, 'ok' ) or diag explain $r;
    like( $r->{html} // '', qr/SAVED about/, 'the saved page' );
    is( theme_of( $r->{html} ), 'night', 'in night, not the active day' );
    is( $r->{theme}, 'night', 'and the result says which theme' );
};

subtest 'over a page\'s own theme pin' => sub {
    my $r = mcp( themer => preview_page => { path => '/pinned', theme => 'night' } );
    ok( $r->{ok}, 'ok' ) or diag explain $r;
    is( theme_of( $r->{html} ), 'night', 'the preview asks about night, so night it is' );
};

subtest 'a draft renders in the named theme' => sub {
    my $r = mcp( themer => preview_page => { path => '/about', theme => 'night',
            content => "---\ntitle: D\n---\nDRAFT-MARKER\n" } );
    ok( $r->{ok}, 'ok' ) or diag explain $r;
    like( $r->{html} // '', qr/DRAFT-MARKER/, 'the draft' );
    is( theme_of( $r->{html} ), 'night', 'in night' );
    ok( $r->{draft}, 'still a draft preview' );
};

subtest 'NOTHING IS WRITTEN' => sub {
    is_deeply( changes( $before, snapshot() ), [], 'every file under the site is as it was' );
    ok( scalar( keys %$before ) > 10, 'and the comparison saw the site (' . scalar( keys %$before ) . ' entries)' );
};

subtest 'it needs manage_themes or manage_layouts as well' => sub {
    my $r = mcp( writer => preview_page => { path => '/about', theme => 'night' } );
    ok( !$r->{ok}, 'a content-only grant is refused' );
    is( $r->{kind}, 'forbidden', 'as forbidden' ) or diag explain $r;
    like( $r->{error} // '', qr/manage_themes or manage_layouts/, 'naming what it needs' );
    unlike( $r->{html} // '', qr/SAVED about/, 'and nothing rendered' );
};

subtest 'a theme that is not installed is refused' => sub {
    my $r = mcp( themer => preview_page => { path => '/about', theme => 'nope' } );
    is( $r->{kind}, 'not-found', 'no such theme: refused' ) or diag explain $r;
    my $e = mcp( themer => preview_page => { path => '/about', theme => 'elsewhere' } );
    is( $e->{kind}, 'theme-not-installed', 'installed for another layout only: refused' ) or diag explain $e;
    like( $e->{error} // '', qr/'default'/, 'naming the layout the page renders with' );
    ok( !defined $e->{html}, 'and no render handed back' );
    my $bad = mcp( themer => preview_page => { path => '/about', theme => '../day' } );
    ok( !$bad->{ok}, 'a name that is not a theme name: refused' );
};

subtest 'the refusals wrote nothing but their audit rows' => sub {
    my $audit = 'public_html/lazysite/logs/audit.log';
    ( my $dir = $audit ) =~ s{/[^/]+\z}{};
    is_deeply( changes( $before, snapshot() ), [ "added $dir", "added $audit" ], 'only the audit trail changed' );
    open my $fh, '<', "$site/$audit" or die "$audit: $!";
    my @rows = grep { /\S/ } <$fh>;
    close $fh;
    is( scalar @rows, 4, 'one row per refusal' ) or diag @rows;
};

subtest 'without theme, the active one, as before' => sub {
    my $r = mcp( writer => preview_page => { path => '/about' } );
    ok( $r->{ok}, 'ok for a content-only grant' ) or diag explain $r;
    is( theme_of( $r->{html} ), 'day', 'in the active theme' );
    ok( !exists $r->{theme}, 'and names no preview theme' );
};

done_testing;
