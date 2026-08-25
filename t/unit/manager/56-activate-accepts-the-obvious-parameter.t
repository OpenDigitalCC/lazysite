#!/usr/bin/perl
# SM261: theme-activate and layout-activate accept the name in the parameter a
# caller will actually reach for.
#
# Both take the NAME in a parameter called `path` - the file-ish parameter
# everywhere else on this surface - so someone building a call from the action
# reference sends `theme=` or `layout=`. SM247 made that survivable: an empty
# name is now an error naming `path`, rather than the silent deactivation that
# stripped a live site's theme and returned ok:1. But an error only helps a
# caller who has already made the call. This removes the trap instead of
# reporting it.
#
# `path` DEFAULTS to '/', so "absent" means empty or '/'. Testing length alone
# would never reach the alias - the same defaulting that made SM247 read a
# missing parameter as an instruction.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Cwd        ();
use FindBin;
use lib "$FindBin::Bin/../../../lib";
use Lazysite::Manager::Themes ();
use Lazysite::Manager::Files  ();

my $d = Cwd::realpath( tempdir( CLEANUP => 1 ) );
make_path( "$d/lazysite/layouts/base/themes/house", "$d/lazysite/manager/locks" );
open my $tj, '>', "$d/lazysite/layouts/base/themes/house/theme.json" or die $!;
print {$tj} '{"name":"house","version":"1.0.0","layouts":["base"],"config":{}}';
close $tj;

$Lazysite::Manager::Themes::DOCROOT      = $d;
$Lazysite::Manager::Themes::LAZYSITE_DIR = "$d/lazysite";
$Lazysite::Manager::Files::DOCROOT       = $d;
$Lazysite::Manager::Files::LOCK_DIR      = "$d/lazysite/manager/locks";

sub write_conf { open my $f, '>', "$d/lazysite/lazysite.conf" or die $!; print {$f} $_[0]; close $f }
sub conf { open my $f, '<', "$d/lazysite/lazysite.conf" or die $!; local $/; <$f> }

# The dispatcher's resolution, mirrored: this is the logic under test, and
# keeping it here in one line makes the property visible rather than buried in
# the API script's if-chain.
sub resolve {
    my ( $path, $params, $key ) = @_;
    return ( length($path) && $path ne '/' ) ? $path : ( $params->{$key} // '' );
}

# --- the name in `theme=`, path left at its default -------------------------
{
    write_conf("site_name: T\nlayout: base\n");
    my $name = resolve( '/', { theme => 'house' }, 'theme' );
    is( $name, 'house', "theme= is used when path is at its default '/'" );

    my $r = Lazysite::Manager::Themes::action_theme_activate( $name, {} );
    ok( $r->{ok}, 'and the theme activates' ) or diag( $r->{error} // '' );
    like( conf(), qr/^theme: house$/m, 'the conf carries it' );
}

# --- path still wins when genuinely given -----------------------------------
{
    my $name = resolve( 'house', { theme => 'other' }, 'theme' );
    is( $name, 'house', 'an explicit path takes precedence over the alias' );
}

# --- neither given is still an ERROR, not a deactivation --------------------
# The SM247 guarantee has to survive the alias: an absent name must never be
# read as "remove the theme".
{
    write_conf("site_name: T\nlayout: base\ntheme: house\n");
    my $name = resolve( '/', {}, 'theme' );
    is( $name, '', 'nothing given resolves to empty' );

    my $r = Lazysite::Manager::Themes::action_theme_activate( $name, {} );
    ok( !$r->{ok}, 'and an empty name is an ERROR' );
    is( $r->{kind}, 'missing-parameter', 'reported as a missing parameter' );
    like( conf(), qr/^theme: house$/m,
        'the site theme is UNTOUCHED - the SM247 guarantee survives the alias' );
}

# --- deliberate deactivation still works ------------------------------------
{
    my $r = Lazysite::Manager::Themes::action_theme_activate( '', { deactivate => 1 } );
    ok( $r->{ok}, 'deactivate=1 still deactivates' );
    unlike( conf(), qr/^theme: /m, 'and clears the pointer' );
}

# --- the same resolution for layout= ----------------------------------------
{
    is( resolve( '/',    { layout => 'base' },  'layout' ), 'base', 'layout= is used' );
    is( resolve( 'base', { layout => 'other' }, 'layout' ), 'base', 'path wins' );
    is( resolve( '/',    {}, 'layout' ), '', 'nothing resolves to empty' );
}

# --- the dispatcher really carries this ------------------------------------
# The mirrored helper above proves the rule; this proves the API script uses it,
# which is the part that can silently stop being true.
{
    open my $fh, '<', "$FindBin::Bin/../../../lazysite-manager-api.pl" or die $!;
    my $src = do { local $/; <$fh> };
    close $fh;
    like( $src, qr/theme-activate.*?\n.*?\$params\{theme\}/s,
        'theme-activate falls back to $params{theme}' );
    like( $src, qr/layout-activate.*?\n.*?\$params\{layout\}/s,
        'layout-activate falls back to $params{layout}' );
    like( $src, qr/\$path ne '\/'/,
        "and treats the defaulted '/' as absent, not as a name" );
}

# --- the audit row names the theme, whichever spelling was used -------------
# SM553: the alias resolution above lived only in the dispatch branch, so the
# audit block still saw path='/' and recorded target '/' for the alias
# spellings. An audit row for an activation is the record of what went live;
# it has to carry the name either way.
{
    use lib "$FindBin::Bin/../../lib";
    require TestHelper;
    require Digest::SHA;
    my $SECRET = 'testsecret0123456789abcdef0123456789abcdef0123456789abcdef012345';
    my $ad     = Cwd::realpath( tempdir( CLEANUP => 1 ) );
    make_path( "$ad/lazysite/auth", "$ad/lazysite/logs" );
    open my $cf, '>', "$ad/lazysite/lazysite.conf" or die $!;
    print {$cf} "site_name: T\nsite_url: http://localhost\n";
    close $cf;
    open my $sf, '>', "$ad/lazysite/auth/.secret" or die $!;
    print {$sf} "$SECRET\n";
    close $sf;
    my $stub = "$ad/users-stub.pl";
    open my $st, '>', $stub or die $!;
    print {$st} <<'STUB';
#!/usr/bin/perl
use strict; use warnings; use JSON::PP qw(encode_json);
my $in = do { local $/; <STDIN> };
print encode_json({ ok => 1, settings => { manage_themes => 1, manage_layouts => 1, ui => 1 }, users => [], groups => {} });
STUB
    close $st;
    chmod 0755, $stub;
    my $csrf = Digest::SHA::hmac_sha256_hex( "csrf:admin:" . int( time() / 3600 ), $SECRET );
    my $post = sub {
        my ($qs) = @_;
        TestHelper::run_script(
            'lazysite-manager-api.pl',
            stdin => '{}',
            env   => {
                DOCUMENT_ROOT         => $ad,
                REQUEST_METHOD        => 'POST',
                QUERY_STRING          => $qs,
                CONTENT_LENGTH        => 2,
                HTTP_X_REMOTE_USER    => 'admin',
                LAZYSITE_AUTH_TRUSTED => 1,
                HTTP_X_CSRF_TOKEN     => $csrf,
                LAZYSITE_USERS_TOOL   => $stub,
            }
        );
    };
    $post->('action=theme-activate&path=sky');
    $post->('action=theme-activate&theme=sky');
    $post->('action=layout-activate&layout=grid');
    open my $al, '<', "$ad/lazysite/logs/audit.log" or die "no audit log: $!";
    my @l = <$al>;
    close $al;
    is( scalar( grep { /\| theme-activate \| sky \|/ } @l ), 2,
        'theme-activate audits target "sky" for path= AND for theme=' );
    ok( ( grep { /\| layout-activate \| grid \|/ } @l ),
        'layout-activate audits target "grid" for layout=' );
    ok( !( grep { /\| (?:theme|layout)-activate \| \/ \|/ } @l ),
        'no activation audits a bare "/" target' );
}

done_testing();
