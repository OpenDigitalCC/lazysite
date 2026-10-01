#!/usr/bin/perl
# SM261, then SM920: theme-activate and layout-activate take the name in the
# parameter a caller actually reaches for - and in NO OTHER.
#
# SM261 added `theme=` and `layout=` because `path` is the file-ish parameter
# everywhere else on this surface, so a caller building from the action reference
# sends the specific one. It kept `path` as an alias, and SM920 found what that
# cost: `path` TOOK PRECEDENCE. A live site sent `path=odcc&theme=odcc-b`, was
# answered ok:true, and went on serving the old theme, because the generic
# parameter named the directory and the specific one named the theme. Sending both
# is the natural thing to do when a reference lists both.
#
# RULED 2026-09-30 on the prior question - "why do we have the option of both?" -
# and the answer was that there was no reason. `path` is retired for these two
# actions, with no deprecation window, as SM903 did for theme-rename.
#
# SO THIS FILE NOW ASSERTS THE OPPOSITE OF WHAT IT ONCE DID for `path`: not that it
# works, but that it does not - and that the refusal names the parameter that does.
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
$Lazysite::Manager::Common::DOCROOT      = $d;              # as the dispatcher sets it
$Lazysite::Manager::Files::DOCROOT       = $d;
$Lazysite::Manager::Files::LOCK_DIR      = "$d/lazysite/manager/locks";

sub write_conf { open my $f, '>', "$d/lazysite/lazysite.conf" or die $!; print {$f} $_[0]; close $f }
sub conf { open my $f, '<', "$d/lazysite/lazysite.conf" or die $!; local $/; <$f> }

# The dispatcher's resolution, mirrored: one parameter, no fallback. SM920 took
# the `path` arm out, and the mirror goes with it - a mirror that still carried
# the alias would be the only place in the tree where it still existed.
sub resolve {
    my ( $params, $key ) = @_;
    return $params->{$key} // '';
}

# --- the name in `theme=` ---------------------------------------------------
{
    write_conf("site_name: T\nlayout: base\n");
    my $name = resolve( { theme => 'house' }, 'theme' );
    is( $name, 'house', 'theme= is the name' );

    my $r = Lazysite::Manager::Themes::action_theme_activate( $name, {} );
    ok( $r->{ok}, 'and the theme activates' ) or diag( $r->{error} // '' );
    like( conf(), qr/^theme: house$/m, 'the conf carries it' );
}

# --- `path` is not a spelling of it any more --------------------------------
# The whole of SM920: `path` used to WIN over `theme`, so a caller sending both -
# which a reference listing both invites - activated the directory name and was
# told ok. Now the generic parameter names nothing.
{
    write_conf("site_name: T\nlayout: base\ntheme: house\n");
    my $name = resolve( { path => 'other', theme => 'sky' }, 'theme' );
    is( $name, 'sky', 'theme= is what is read, whatever else was sent' );

    my $only_path = resolve( { path => 'other' }, 'theme' );
    is( $only_path, '',
        'and path= alone resolves to NOTHING, so it reaches the refusal below '
            . 'rather than quietly activating something' );
}

# --- neither given is still an ERROR, not a deactivation --------------------
# The SM247 guarantee: an absent name must never be read as "remove the theme".
{
    write_conf("site_name: T\nlayout: base\ntheme: house\n");
    my $name = resolve( {}, 'theme' );
    is( $name, '', 'nothing given resolves to empty' );

    my $r = Lazysite::Manager::Themes::action_theme_activate( $name, {} );
    ok( !$r->{ok}, 'and an empty name is an ERROR' );
    is( $r->{kind}, 'missing-parameter', 'reported as a missing parameter' );
    like( $r->{error}, qr/`theme`/,
        'naming the parameter that EXISTS - it named `path`, which is the one '
            . 'that was retired, so the refusal sent a caller back to the cause' );
    like( conf(), qr/^theme: house$/m,
        'the site theme is UNTOUCHED - the SM247 guarantee is independent of '
            . 'which parameter carries the name' );
}

# --- deliberate deactivation still works ------------------------------------
{
    my $r = Lazysite::Manager::Themes::action_theme_activate( '', { deactivate => 1 } );
    ok( $r->{ok}, 'deactivate=1 still deactivates' );
    unlike( conf(), qr/^theme: /m, 'and clears the pointer' );
}

# --- the same resolution for layout= ----------------------------------------
{
    is( resolve( { layout => 'base' }, 'layout' ), 'base', 'layout= is the name' );
    is( resolve( { path => 'base' },   'layout' ), '',
        'path= names nothing here either' );
    is( resolve( {}, 'layout' ), '', 'nothing resolves to empty' );
}

# --- the dispatcher really carries this ------------------------------------
# The mirrored helper above proves the rule; this proves the API script uses it,
# which is the part that can silently stop being true.
{
    open my $fh, '<', "$FindBin::Bin/../../../lazysite-manager-api.pl" or die $!;
    my $src = do { local $/; <$fh> };
    close $fh;
    # THE BRANCH, not the file. The first draft of this asserted `unlike($src,
    # qr/theme-activate'.*?\$path/s)` - and with /s that `.*?` runs to the next
    # `$path` ANYWHERE below, so it failed against correct code. A gate that reads
    # the whole script to make a claim about four lines is measuring the script.
    for my $pair ( [ 'theme', 'theme' ], [ 'layout', 'layout' ] ) {
        my ( $action, $key ) = @$pair;
        my ($branch) = $src =~ /(elsif \( \$action eq '$action-activate' \) \{.*?\n\})/s;
        ok( $branch, "the $action-activate branch was found" ) or next;
        like( $branch, qr/\$params\{$key\}/, "$action-activate reads \$params{$key}" );
        unlike( $branch, qr/\$path/,
            "and NOT \$path - SM920 retired it, and a fallback left here would "
                . 'restore the precedence that served the old theme and said ok' );
    }
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
    $post->('action=theme-activate&theme=sky');
    $post->('action=layout-activate&layout=grid');
    open my $al, '<', "$ad/lazysite/logs/audit.log" or die "no audit log: $!";
    my @l = <$al>;
    close $al;
    is( scalar( grep { /\| theme-activate \| sky \|/ } @l ), 1,
        'theme-activate audits target "sky" for theme=' );
    ok( ( grep { /\| layout-activate \| grid \|/ } @l ),
        'layout-activate audits target "grid" for layout=' );
    ok( !( grep { /\| (?:theme|layout)-activate \| \/ \|/ } @l ),
        'no activation audits a bare "/" target' );
}

done_testing();
