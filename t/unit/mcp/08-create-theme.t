#!/usr/bin/perl
# SM205: the create_theme MCP write tool (capability manage_themes, AUDITED).
# Eager validation rejects a bad name / a forbidden config value with
# kind:validation BEFORE writing anything; the happy path scaffolds theme.json +
# assets/main.css (config-only copies the layout default CSS); coverage warnings
# fire against a declared-tokens (SM203) layout; activate:true mirrors the assets
# and flips the active pointer.
use strict;
use warnings;
use Test::More;
use JSON::PP   qw(encode_json decode_json);
use IPC::Open2 qw(open2);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;

my $root = "$FindBin::Bin/../../..";
my $mcp  = "$root/lazysite-mcp.pl";
my $d    = tempdir( CLEANUP => 1 );

# Two layouts: 'base' declares a token vocabulary (SM203); 'plain' does not.
# Each has a default theme whose main.css is the copy source.
make_path(
    "$d/lazysite/layouts/base/themes/blue/assets",
    "$d/lazysite/layouts/plain/themes/grey/assets",
);

open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
print {$cf} "site_name: Demo\nmcp_enabled: true\nlayout: base\ntheme: blue\n";
close $cf;

# base layout.tt (activation validates it compiles) + declared tokens.
open my $lt, '>', "$d/lazysite/layouts/base/layout.tt" or die $!;
print {$lt} '<html>[% content %]</html>';
close $lt;
open my $lj, '>', "$d/lazysite/layouts/base/layout.json" or die $!;
print {$lj} encode_json( {
        name   => 'base', version => '1.0.0', default_theme => 'blue',
        tokens => { colours => [qw(primary text)], fonts => ['body'] },
} );
close $lj;
open my $bt, '>', "$d/lazysite/layouts/base/themes/blue/theme.json" or die $!;
print {$bt} encode_json( {
        name   => 'blue', version => '1.0.0', layouts => ['base'],
        config => { colours => { primary => '#0044CC', text => '#111' },
            fonts => { body => 'Inter' } },
} );
close $bt;
open my $bc, '>', "$d/lazysite/layouts/base/themes/blue/assets/main.css" or die $!;
print {$bc} "/* blue default css MARKER-BLUE */\nbody { color: var(--theme-colours-text, #000); }\n";
close $bc;

# plain layout (no declared tokens block).
open my $plt, '>', "$d/lazysite/layouts/plain/layout.tt" or die $!;
print {$plt} '<html>[% content %]</html>';
close $plt;
open my $plj, '>', "$d/lazysite/layouts/plain/layout.json" or die $!;
print {$plj} encode_json(
    { name => 'plain', version => '1.0.0', default_theme => 'grey' } );
close $plj;
open my $gt, '>', "$d/lazysite/layouts/plain/themes/grey/theme.json" or die $!;
print {$gt} encode_json(
    { name => 'grey', version => '1.0.0', layouts => ['plain'], config => {} } );
close $gt;
open my $gc, '>', "$d/lazysite/layouts/plain/themes/grey/assets/main.css" or die $!;
print {$gc} "/* grey default MARKER-GREY */\n";
close $gc;

# Stub users-tool: everyone holds mcp + manage_themes.
my $stub = "$d/users-stub.pl";
open my $sf, '>', $stub or die $!;
print $sf <<'STUB';
#!/usr/bin/perl
use strict; use warnings; use JSON::PP qw(encode_json decode_json);
my $in = do { local $/; <STDIN> };
print encode_json({ ok => 1, settings => { mcp => 1, manage_themes => 1 } });
STUB
close $sf;
chmod 0755, $stub;

sub mcp {
    my ( $payload, %extra ) = @_;
    my $body = encode_json($payload);
    local %ENV = %ENV;
    $ENV{DOCUMENT_ROOT}       = $d;
    $ENV{REQUEST_METHOD}      = 'POST';
    $ENV{CONTENT_LENGTH}      = length $body;
    $ENV{LAZYSITE_USERS_TOOL} = $stub;
    $ENV{HTTP_AUTHORIZATION}  = $extra{auth} if defined $extra{auth};
    my ( $out, $in );
    my $pid = open2( $out, $in, $^X, $mcp );
    print $in $body;
    close $in;
    my $resp = do { local $/; <$out> };
    close $out;
    waitpid $pid, 0;
    my ($jb) = $resp =~ /\r?\n\r?\n(.*)/s;
    return ( defined $jb && length $jb ) ? eval { decode_json($jb) } : undef;
}
sub call { mcp( { jsonrpc => '2.0', id => 1, method => 'tools/call',
            params => { name => $_[0], arguments => $_[1] || {} } }, auth => $_[2] ) }
sub sc { my $r = shift; $r && $r->{result} ? $r->{result}{structuredContent} : undef }

my $ok = 'Bearer agent:lzs_tok';

# --- eager validation: a bad name is rejected, nothing written --------------
{
    my $r = sc( call( 'create_theme',
            { layout => 'base', name => 'bad name', config => {} }, $ok ) );
    ok( $r && !$r->{ok}, 'a name with a space is rejected' );
    is( $r->{kind}, 'validation', 'kind=validation for a bad name' );
    ok( !-d "$d/lazysite/layouts/base/themes/bad name",
        'nothing was scaffolded for the rejected name' );
}

# --- eager validation: a forbidden config value char is rejected ------------
{
    my $r = sc( call( 'create_theme',
            { layout => 'base', name => 'badval',
                config => { colours => { primary => 'red; }<x>' } } }, $ok ) );
    ok( $r && !$r->{ok}, 'a config value with a forbidden char is rejected' );
    is( $r->{kind}, 'validation', 'kind=validation for a forbidden value' );
    ok( !-d "$d/lazysite/layouts/base/themes/badval",
        'nothing scaffolded for the rejected value' );
}

# --- eager validation: an uninstalled layout is rejected --------------------
{
    my $r = sc( call( 'create_theme',
            { layout => 'nope', name => 'x', config => {} }, $ok ) );
    ok( $r && !$r->{ok}, 'an uninstalled layout is rejected' );
    is( $r->{kind}, 'validation', 'kind=validation for an unknown layout' );
}

# --- happy path (config only): scaffolds theme.json + assets/main.css, and
#     copies the layout default theme CSS -----------------------------------
{
    my $r = sc( call( 'create_theme',
            { layout => 'base', name => 'ocean',
                config => { colours => { primary => '#006', text => '#012' },
                    fonts => { body => 'Georgia' } } }, $ok ) );
    ok( $r && $r->{ok}, 'config-only create_theme succeeds' ) or diag encode_json($r);
    ok( -f "$d/lazysite/layouts/base/themes/ocean/theme.json",
        'theme.json scaffolded' );
    ok( -f "$d/lazysite/layouts/base/themes/ocean/assets/main.css",
        'assets/main.css scaffolded (under assets/, not root)' );

    open my $mf, '<', "$d/lazysite/layouts/base/themes/ocean/assets/main.css" or die $!;
    my $css = do { local $/; <$mf> }; close $mf;
    like( $css, qr/MARKER-BLUE/, 'main.css copied from the layout default theme' );

    open my $tf, '<', "$d/lazysite/layouts/base/themes/ocean/theme.json" or die $!;
    my $tj = decode_json( do { local $/; <$tf> } ); close $tf;
    is_deeply( $tj->{layouts}, ['base'], 'theme.json declares the layout' );
    is( $tj->{version},                  '1.0.0', 'default version 1.0.0' );
    is( $tj->{config}{colours}{primary}, '#006',  'config persisted' );
    ok( length( $tj->{author} // '' ), 'author stamped from the acting identity' );

    # ocean covers every declared token -> no warnings.
    ok( !( $r->{warnings} && @{ $r->{warnings} } ),
        'a fully-covering config reports no coverage warnings' );
    like( $r->{preview}, qr{themes/ocean/assets/main\.css},
        'pre-activation preview points at the source CSS' );
}

# --- coverage warnings against the declared-tokens layout -------------------
{
    my $r = sc( call( 'create_theme',
            { layout => 'base', name => 'sparse',
                config => { colours => { primary => '#000', accent => '#0AF' } } }, $ok ) );
    ok( $r             && $r->{ok}, 'sparse create_theme still succeeds (warn-only)' );
    ok( $r->{warnings} && @{ $r->{warnings} }, 'coverage warnings present' )
        or diag encode_json($r);
    ok( ( grep { /colours\.text/ } @{ $r->{warnings} } ),
        'omitted declared token colours.text warned' );
    ok( ( grep { /fonts\.body/ } @{ $r->{warnings} } ),
        'omitted declared token fonts.body warned' );
    ok( ( grep { /colours\.accent/ } @{ $r->{warnings} } ),
        'undeclared supplied token colours.accent warned' );
}

# --- activate:true mirrors the assets and flips the pointer -----------------
{
    my $r = sc( call( 'create_theme',
            { layout => 'base', name => 'live', activate => JSON::PP::true,
                config => { colours => { primary => '#0A0', text => '#010' },
                    fonts => { body => 'Inter' } } }, $ok ) );
    ok( $r && $r->{ok}, 'activate:true create_theme succeeds' ) or diag encode_json($r);
    ok( -f "$d/lazysite-assets/base/live/main.css",
        'assets mirrored to /lazysite-assets after activation' );
    open my $cf2, '<', "$d/lazysite/lazysite.conf" or die $!;
    my $conf = do { local $/; <$cf2> }; close $cf2;
    like( $conf, qr/^theme:\s*live$/m, 'active theme pointer flipped to the new theme' );
    like( $r->{preview}, qr{lazysite-assets/base/live/main\.css},
        'post-activation preview points at the mirror URL' );
}

# --- a layout with NO declared block: no coverage warnings ------------------
{
    my $r = sc( call( 'create_theme',
            { layout => 'plain', name => 'slate',
                config => { colours => { primary => '#222' } } }, $ok ) );
    ok( $r && $r->{ok}, 'create under an undeclared-block layout succeeds' );
    ok( !( $r->{warnings} && @{ $r->{warnings} } ),
        'no declared block => no coverage warnings' );
    open my $mf, '<', "$d/lazysite/layouts/plain/themes/slate/assets/main.css" or die $!;
    my $css = do { local $/; <$mf> }; close $mf;
    like( $css, qr/MARKER-GREY/, 'copied the plain layout default CSS' );
}

# --- an existing theme name is refused --------------------------------------
{
    my $r = sc( call( 'create_theme',
            { layout => 'base', name => 'ocean', config => {} }, $ok ) );
    ok( $r && !$r->{ok}, 'a duplicate theme name is refused' );
    is( $r->{kind}, 'exists', 'kind=exists for a duplicate' );
}

# --- write_file of a theme.json folds in validator warnings (no reject) ------
{
    my $bad = encode_json( {
            name   => 'via_write', layouts => ['base'],
            config => { colours => { primary => 'ok', text => 'has;brace{' } },
    } );
    my $r = sc( call( 'write_file',
            { path => 'lazysite/layouts/base/themes/viawrite/theme.json',
                content => $bad }, $ok ) );
    ok( $r && $r->{ok}, 'write_file of a theme.json still succeeds (warn-only)' )
        or diag encode_json($r);
    ok( $r->{warnings} && @{ $r->{warnings} },
        'theme.json write folds in validator warnings' )
        or diag encode_json($r);
    ok( ( grep { /forbidden character/ } @{ $r->{warnings} } ),
        'the forbidden-char value is flagged as a warning' );
}

done_testing();
