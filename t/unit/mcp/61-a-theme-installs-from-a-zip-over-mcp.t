#!/usr/bin/perl
# SM1291 (K-5): A THEME INSTALLS FROM A ZIP OVER MCP, ITS FONTS WITH IT.
#
# A designer staged theme.json and main.css over MCP and handed the fonts over
# separately, because upload_file takes base64 in the call and five woff2 files
# were about 115 KB of text - and the manager's Upload Theme, which takes a zip,
# had no MCP twin (lazysite.io, 2026-10-22). install_theme is that twin: the
# same function (Manager::Themes::action_theme_upload), so the same checks.
#
# What this holds, over the MCP CGI as a client sends it:
#   - a zip installs: theme.json and the stylesheet under the layout, the
#     fonts byte for byte in the served asset mirror, nothing activated;
#   - the audit row is theme-upload's, naming the theme;
#   - a second install of the same name goes BESIDE the first, never over it;
#   - the caller may delete_theme what it installed (it is recorded as theirs);
#   - refused: without manage_themes, bad base64, an entry with `..`, a
#     symbolic link, a file type the web server runs, a theme.json without
#     layouts or naming a layout that is not installed, and an archive over
#     the site's upload limit - each installing nothing.
use strict;
use warnings;
use Test::More;
use File::Path   qw(make_path);
use JSON::PP     qw(encode_json decode_json);
use MIME::Base64 qw(encode_base64);
use File::Temp   qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root env_passthrough site_tempdir run_child);

plan skip_all => 'Archive::Zip is not installed' unless eval { require Archive::Zip; 1 };

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
sub slurp { open my $f, '<:raw', $_[0] or return undef; local $/; my $t = <$f>; close $f; $t }

spit( "$d/lazysite/layouts/default/layout.tt", '<html><body>[% content %]</body></html>' );
spit( "$d/lazysite/layouts/default/themes/day/theme.json",
    encode_json( { name => 'day', version => '1.0', layouts => ['default'] } ) );
spit( "$d/lazysite/lazysite.conf",
    "site_name: T\nmcp_enabled: true\nlayout: default\ntheme: day\nmanager_upload_max_mb: 1\n" );
spit( "$d/index.md", "---\ntitle: Home\n---\nHome.\n" );

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

# A zip of { name => bytes }, and of { name => target } as symbolic links.
#
# THE LINKS ARE MADE BY HAND. Archive::Zip 1.68 writing a symbolic-link member
# calls symlink() on its output handle and leaves a link named like
# `GLOB(0x...)` in the working directory (seen while building this test), so the
# links are written as ordinary members and marked as links afterwards in the
# central directory: made by Unix (version-made-by high byte 3) and S_IFLNK in
# the external attributes - what `zip --symlinks` writes.
sub zip_of {
    my ( $files, $links ) = @_;
    $links ||= {};
    my $z = Archive::Zip->new;
    $z->addString( $files->{$_}, $_ ) for sort keys %$files;
    $z->addString( $links->{$_}, $_ ) for sort keys %$links;
    my $out = '';
    open my $fh, '>', \$out or die;
    binmode $fh;
    $z->writeToFileHandle($fh) == Archive::Zip::AZ_OK() or die 'zip write failed';
    close $fh;
    my $at = 0;
    while ( ( $at = index( $out, "PK\x01\x02", $at ) ) >= 0 ) {
        my $nl   = unpack( 'v', substr( $out, $at + 28, 2 ) );
        my $name = substr( $out, $at + 46, $nl );
        if ( exists $links->{$name} ) {
            substr( $out, $at + 5,  1 ) = chr(3);
            substr( $out, $at + 38, 4 ) = pack( 'V', 0120777 << 16 );
        }
        $at += 46 + $nl;
    }
    return $out;
}
sub install { my ( $user, $zip ) = @_; mcp( $user, install_theme => { content_base64 => encode_base64( $zip, '' ), filename => 'kit.zip' } ) }

my $FONT = join '', map { chr( ( $_ * 37 ) % 256 ) } 0 .. 4095;    # binary, every byte value
my %KIT  = (
    'theme.json'               => encode_json( { name => 'kit', version => '1.0', layouts => ['default'] } ),
    'main.css'                 => "body { font-family: Kit; }\n",
    'assets/main.css'          => "\@font-face { font-family: Kit; src: url(fonts/kit.woff2); }\n",
    'assets/fonts/kit.woff2'   => $FONT,
);
my $THEME  = "$d/lazysite/layouts/default/themes";
my $MIRROR = "$d/lazysite-assets/default";

subtest 'a zip installs, its fonts with it' => sub {
    my $r = install( themer => zip_of( \%KIT ) );
    ok( $r->{ok}, 'ok' ) or diag explain $r;
    is( $r->{name}, 'kit', 'installed as kit' );
    is_deeply( $r->{layouts}, ['default'], 'under the layout it names' );
    ok( -f "$THEME/kit/theme.json", 'theme.json is under the layout' );
    is( slurp("$THEME/kit/main.css"), $KIT{'main.css'}, 'with its stylesheet' );
    is( slurp("$MIRROR/kit/fonts/kit.woff2"), $FONT, 'the font is in the served mirror, byte for byte' );
    is( slurp("$MIRROR/kit/main.css"), $KIT{'assets/main.css'}, 'beside the asset stylesheet' );
    like( slurp("$d/lazysite/lazysite.conf"), qr/^theme: day$/m, 'nothing was activated' );
    like( $r->{next} // '', qr/preview_page/, 'and it says how to look before activating' );
};

subtest 'the audit row is theme-upload\'s' => sub {
    my @rows = grep { /theme-upload/ } split /\n/, ( slurp("$d/lazysite/logs/audit.log") // '' );
    is( scalar @rows, 1, 'one theme-upload row' ) or diag @rows;
    like( $rows[0] // '', qr/\bkit\b/,  'naming the theme' );
    like( $rows[0] // '', qr/\bok\b/,   'as ok' );
    like( $rows[0] // '', qr/\bmcp\b/,  'from mcp' );
};

subtest 'the same name again goes beside it, never over it' => sub {
    my %v2 = ( %KIT, 'main.css' => "body { font-family: Kit2; }\n" );
    my $r  = install( themer => zip_of( \%v2 ) );
    ok( $r->{ok}, 'ok' ) or diag explain $r;
    like( $r->{installed_as} // '', qr/\A\d{8}-kit\z/, "installed as $r->{installed_as}" );
    is( slurp("$THEME/kit/main.css"), $KIT{'main.css'}, 'the first install is untouched' );
};

subtest 'the caller may delete what it installed' => sub {
    my $r = mcp( themer => delete_theme => { theme => 'kit' } );
    ok( $r->{ok}, 'delete_theme takes it' ) or diag explain $r;
    ok( !-d "$THEME/kit", 'and it is gone' );
};

my $NEXT = 0;
sub refused {
    my ( $what, $user, $zip, $like, $raw ) = @_;
    my $name = 'r' . ++$NEXT;
    my $r = defined $raw
        ? mcp( $user, install_theme => { content_base64 => $raw } )
        : install( $user, $zip->($name) );
    ok( !$r->{ok}, "$what: refused" ) or diag explain $r;
    like( $r->{error} // '', $like, "$what: and says why" );
    ok( !-e "$THEME/$name", "$what: nothing installed" );
    return $r;
}
my $json = sub { encode_json( { name => $_[0], version => '1', layouts => ['default'] } ) };

subtest 'refusals' => sub {
    my $w = refused( 'without manage_themes', writer => sub { zip_of( { 'theme.json' => $json->( $_[0] ) } ) },
        qr/needs manage_themes/ );
    is( $w->{rpc_code}, -32002, 'as a capability refusal' );
    refused( 'bad base64', themer => undef, qr/not valid base64/, '!!not base64!!' );
    refused( 'an entry climbing out', themer => sub {
            zip_of( { 'theme.json' => $json->( $_[0] ), '../escape.css' => 'x' } ) }, qr/Zip slip/ );
    refused( 'a symbolic link', themer => sub {
            zip_of( { 'theme.json' => $json->( $_[0] ) }, { 'assets/passwd' => '/etc/passwd' } ) },
        qr/symbolic link/ );
    refused( 'a file the web server runs', themer => sub {
            zip_of( { 'theme.json' => $json->( $_[0] ), 'assets/x.php' => '<?php ?>' } ) }, qr/web server would run/ );
    refused( 'no layouts', themer => sub {
            zip_of( { 'theme.json' => encode_json( { name => $_[0] } ) } ) }, qr/layouts/ );
    refused( 'a layout not installed', themer => sub {
            zip_of( { 'theme.json' => encode_json( { name => $_[0], layouts => ['nope'] } ) } ) }, qr/missing layout/ );
    my $big = refused( 'over the upload limit', themer => sub {
            my $noise = join '', map { chr( int( rand 256 ) ) } 1 .. ( 1024 * 1024 + 4096 );
            zip_of( { 'theme.json' => $json->( $_[0] ), 'assets/big.bin' => $noise } ) }, qr/at most 1048576/ );
    is( $big->{kind}, 'too-large', 'as too-large' );
    ok( !-e "$MIRROR/r$_", "no asset mirror for refusal $_" ) for 1 .. $NEXT;
};

done_testing;
