#!/usr/bin/perl
# SM204: the MCP theme_tokens read tool (capability manage_themes, NOT audited).
# It reports a theme/layout's design-token vocabulary without activating
# anything. Three branches are exercised: an explicit theme returns THAT theme's
# config verbatim; a layout alone returns derived:true plus its default theme's
# config as exemplar values; neither arg falls back to the active layout+theme.
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

# A layout 'base' with a declared default_theme 'blue' and TWO themes, each with
# a config block (group -> key -> value). 'blue' is the active theme.
make_path(
    "$d/lazysite/layouts/base/themes/blue",
    "$d/lazysite/layouts/base/themes/red",
);

open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
print {$cf} "site_name: Demo\nmcp_enabled: true\nlayout: base\ntheme: blue\n";
close $cf;

open my $lj, '>', "$d/lazysite/layouts/base/layout.json" or die $!;
print {$lj} encode_json( {
        name          => 'base',
        version       => '1.0.0',
        themes        => [qw(blue red)],
        default_theme => 'blue',
} );
close $lj;

open my $bt, '>', "$d/lazysite/layouts/base/themes/blue/theme.json" or die $!;
print {$bt} encode_json( {
        name    => 'blue',
        version => '2.1.0',
        layouts => ['base'],
        config  => {
            colours => { bg   => '#FFFFFF', accent => '#0044CC' },
            fonts   => { body => 'Inter, sans-serif' },
        },
} );
close $bt;

open my $rt, '>', "$d/lazysite/layouts/base/themes/red/theme.json" or die $!;
print {$rt} encode_json( {
        name    => 'red',
        version => '1.0.0',
        layouts => ['base'],
        config  => { colours => { bg => '#100000', accent => '#CC0011' } },
} );
close $rt;

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

my $ok = 'Bearer agent:lzs_tok';    # holds manage_themes + mcp

# --- explicit theme: that theme's own config, verbatim, not derived ----------
{
    my $r = sc( call( 'theme_tokens', { theme => 'red' }, $ok ) );
    ok( $r && $r->{ok}, 'theme_tokens returns ok for an explicit theme' )
        or diag encode_json($r);
    is( $r->{theme},  'red',  'reports the requested theme' );
    is( $r->{layout}, 'base', 'resolved under the active layout' );
    ok( !$r->{derived}, 'an explicit theme is not derived' );
    is( $r->{tokens}{colours}{bg},     '#100000', 'red bg token value' );
    is( $r->{tokens}{colours}{accent}, '#CC0011', 'red accent token value' );
}

# --- layout only: derived:true + the DEFAULT theme's config as exemplar ------
{
    my $r = sc( call( 'theme_tokens', { layout => 'base' }, $ok ) );
    ok( $r && $r->{ok}, 'theme_tokens returns ok for a layout alone' )
        or diag encode_json($r);
    ok( $r->{derived}, 'layout-only vocabulary is derived (no declared block)' );
    is( $r->{theme}, 'blue', 'exemplar is the active theme of this layout' );
    is( $r->{tokens}{colours}{accent}, '#0044CC',           'exemplar accent from blue' );
    is( $r->{tokens}{fonts}{body},     'Inter, sans-serif', 'exemplar font token' );
    ok( !exists $r->{declared} || !%{ $r->{declared} },
        'no declared block => declared omitted/empty' );
}

# --- neither arg: falls back to the active layout + active theme -------------
{
    my $r = sc( call( 'theme_tokens', {}, $ok ) );
    ok( $r && $r->{ok}, 'theme_tokens defaults to the active pair' )
        or diag encode_json($r);
    is( $r->{layout},              'base',    'active layout' );
    is( $r->{theme},               'blue',    'active theme' );
    is( $r->{tokens}{colours}{bg}, '#FFFFFF', 'active theme bg token' );
}

done_testing();
