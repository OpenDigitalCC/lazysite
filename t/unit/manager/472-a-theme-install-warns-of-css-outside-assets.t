#!/usr/bin/perl
# SM1386: A THEME INSTALL WARNS WHEN ITS STYLESHEETS ARE OUTSIDE assets/.
#
# Only a theme's assets/ is mirrored to /lazysite-assets/<layout>/<theme>/,
# which is what its pages link. A zip with main.css at its root beside
# theme.json installed, previewed and activated with no CSS, and nothing said
# why. Every install door - the control API's theme-upload (the manager's
# Upload Theme), MCP install_theme, and the layout installs (layouts-install,
# layout-install, MCP install_layout), which all install a theme through
# Themes::_install_theme_from_dir - now answers ok with a warning naming each
# stylesheet and where it belongs. Warned, never refused.
#
# Held here: theme-upload over the control API and install_theme over MCP warn,
# naming the file and assets/<file>, and install the theme; a theme with CSS in
# assets/ (with or without another at its root) and a theme with no CSS at all
# are not warned about; _install_theme_from_dir, the layout installs' door,
# carries the same warning.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use File::Path   qw(make_path);
use File::Temp   qw(tempdir);
use JSON::PP     qw(encode_json decode_json);
use MIME::Base64 qw(encode_base64);
use TestHelper     qw(repo_root env_passthrough run_child);
use ManagerSession qw(new_site);

plan skip_all => 'Archive::Zip is not installed' unless eval { require Archive::Zip; 1 };

my $root = repo_root();
my @ALL  = qw(api ui manage_users manage_themes manage_layouts);
my $s    = new_site( root => $root,
    conf => "control_api_enabled: true\nmcp_enabled: true\nlayout: default\ntheme: day\n" );
my $d = $s->docroot;

sub spit {
    my ( $p, $t ) = @_;
    ( my $dir = $p ) =~ s{/[^/]+\z}{};
    make_path($dir);
    open my $fh, '>:raw', $p or die "$p: $!";
    print {$fh} $t;
    close $fh;
    return;
}
spit( "$d/lazysite/layouts/default/layout.tt", '<html><body>[% content %]</body></html>' );
spit( "$d/lazysite/layouts/default/themes/day/theme.json",
    encode_json( { name => 'day', version => '1.0', layouts => ['default'] } ) );

sub zip_of {
    my ($files) = @_;
    my $z = Archive::Zip->new;
    $z->addString( $files->{$_}, $_ ) for sort keys %$files;
    my $out = '';
    open my $fh, '>', \$out or die;
    binmode $fh;
    $z->writeToFileHandle($fh) == Archive::Zip::AZ_OK() or die 'zip write failed';
    close $fh;
    return $out;
}
sub kit {
    my ( $name, %files ) = @_;
    return zip_of( { 'theme.json' => encode_json( { name => $name, version => '1.0',
                    layouts => ['default'] } ), %files } );
}

$s->add_user('human');
$s->grant( 'human', 'g-human', [qw(ui manage_themes)], \@ALL );

sub upload {
    my ($zip) = @_;
    return $s->call( 'human', 'theme-upload', raw => $zip,
        query => 'action=theme-upload&filename=kit.zip',
        content_type => 'application/zip' );
}

# MCP, through the CGI as a client sends it.
spit( "$d/users-stub.pl", <<'STUB' );
#!/usr/bin/perl
use strict; use warnings; use JSON::PP qw(encode_json);
print encode_json( { ok => 1, settings => { mcp => 1, manage_themes => 1 } } );
STUB
chmod 0755, "$d/users-stub.pl";
my $logs = tempdir( CLEANUP => 1 );
sub mcp_install {
    my ($zip) = @_;
    my $body = encode_json( { jsonrpc => '2.0', id => 1, method => 'tools/call',
            params => { name => 'install_theme',
                arguments => { content_base64 => encode_base64( $zip, '' ) } } } );
    local %ENV = ( env_passthrough(),
        PATH                         => $ENV{PATH},
        DOCUMENT_ROOT                => $d,
        REQUEST_METHOD               => 'POST',
        CONTENT_LENGTH               => length $body,
        LAZYSITE_USERS_TOOL          => "$d/users-stub.pl",
        LAZYSITE_FORWARD_DIAGNOSTICS => 'off',
        HTTP_AUTHORIZATION           => 'Bearer themer:lzs_tok',
    );
    open my $e, '>>', "$logs/stderr.log" or die $!;
    my $resp = run_child( [ $^X, "$root/lazysite-mcp.pl" ], stdin => $body, stderr => $e )->{out};
    close $e;
    my ($jb) = ( $resp // '' ) =~ /\r?\n\r?\n(.*)/s;
    my $j = eval { decode_json( $jb // '' ) } || {};
    return $j->{result}{structuredContent} || { ok => 0, error => $j->{error}{message} // 'no body' };
}
my $T = "$d/lazysite/layouts/default/themes";

subtest 'control API theme-upload: main.css at the root installs, with a warning' => sub {
    my $r = upload( kit( 'rootcss', 'main.css' => "body{}\n" ) );
    ok( $r->{ok}, 'installed' ) or diag explain $r;
    ok( -f "$T/rootcss/theme.json", 'on disk' );
    is( scalar @{ $r->{warnings} || [] }, 1, 'one warning' );
    like( $r->{warnings}[0] // '', qr{main\.css \(belongs at assets/main\.css\)},
        'naming the file and where it belongs' );
    like( $r->{warnings}[0] // '', qr{Only assets/ is served}, 'saying why' );
};

subtest 'MCP install_theme: the same warning' => sub {
    my $r = mcp_install( kit( 'mcpcss', 'main.css' => "x{}\n", 'css/print.css' => "y{}\n" ) );
    ok( $r->{ok}, 'installed' ) or diag explain $r;
    like( $r->{warnings}[0] // '', qr{2 stylesheets.*css/print\.css \(belongs at assets/css/print\.css\).*main\.css}s,
        'every stylesheet named' );
};

subtest 'no warning when assets/ has CSS, or when the theme has none' => sub {
    my $r = upload( kit( 'okcss', 'assets/main.css' => "x{}\n" ) );
    ok( $r->{ok} && !$r->{warnings}, 'CSS in assets/: none' ) or diag explain $r;
    $r = upload( kit( 'bothcss', 'main.css' => "x{}\n", 'assets/main.css' => "x{}\n" ) );
    ok( $r->{ok} && !$r->{warnings}, 'CSS in assets/ and at the root: none' ) or diag explain $r;
    $r = upload( kit('nocss') );
    ok( $r->{ok} && !$r->{warnings}, 'no CSS at all: none' ) or diag explain $r;
};

subtest 'the layout installs\' door carries it' => sub {
    my $src = tempdir( CLEANUP => 1 );
    spit( "$src/theme.json", encode_json( { name => 'fromrepo', version => '1.0', layouts => ['default'] } ) );
    spit( "$src/main.css", "x{}\n" );
    require Lazysite::Manager::Themes;
    no warnings 'once';
    local $ENV{DOCUMENT_ROOT}                      = $d;
    local $Lazysite::Manager::Themes::DOCROOT      = $d;
    local $Lazysite::Manager::Themes::LAZYSITE_DIR = "$d/lazysite";
    local $Lazysite::Manager::Common::DOCROOT      = $d;
    my $r = Lazysite::Manager::Themes::_install_theme_from_dir( $src, 'layout-install', 'op' );
    ok( $r->{ok}, 'installed' ) or diag explain $r;
    like( $r->{warnings}[0] // '', qr{main\.css \(belongs at assets/main\.css\)}, 'warned' );
};

done_testing;
