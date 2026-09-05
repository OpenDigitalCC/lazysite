#!/usr/bin/perl
# SM749: the theme or layout BEING SERVED is read-only on every surface, and the
# refusal says what to do instead.
#
# At 0.13.0 WebDAV refused a write into the active theme and the manager, the
# control API and MCP accepted the same write through action_save, which had
# never heard of the rule - SM748's shape with the surfaces reversed. The rule
# now lives in Manager::Common and the choke point asks it on EVERY write verb.
#
# What this holds, at the choke point:
#   - save, binary save, delete, mkdir, move (either end) and copy (either end)
#     into the active theme are refused, with kind active-artifact-refused
#   - the same verbs into a NON-active theme under the same layout are not -
#     that is the workflow's second step and must stay open
#   - the layout's own files are refused while the layout is active
#   - the refusal names the workflow (copy, edit, activate) and the verbs on
#     each surface, and does not offer a way round within one surface
#   - the pure rule answers undef for anything outside lazysite/layouts
# and for the first step the workflow needs:
#   - action_theme_copy copies a theme, names the copy, records the copier,
#     refuses a collision and a same-name copy, and changes nothing live
use strict;
use warnings;
use Test::More;
use FindBin;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP   ();
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
BEGIN { $ENV{LAZYSITE_API_LOAD_ONLY} = 1 }
use TestHelper qw(repo_root);

my $root = repo_root();
my $t    = tempdir( CLEANUP => 1 );
mkdir "$t/site";
my $tmp = "$t/site/public_html";
make_path("$tmp/lazysite/layouts/studio/themes/live/assets");
make_path("$tmp/lazysite/layouts/studio/themes/draft/assets");
make_path("$tmp/lazysite/layouts/other/themes/live");
make_path("$tmp/lazysite-assets/studio/live");

sub put {
    my ( $p, $c ) = @_;
    open my $fh, '>', $p or die "$p: $!";
    print {$fh} $c;
    close $fh;
    return;
}
put( "$tmp/lazysite/lazysite.conf", "site_name: t\nlayout: studio\ntheme: live\n" );
put( "$tmp/lazysite/layouts/studio/themes/live/theme.json",
    JSON::PP::encode_json( { name => 'live', config => { colours => { primary => '#000' } } } ) );
put( "$tmp/lazysite/layouts/studio/themes/live/assets/main.css",  "body{}\n" );
put( "$tmp/lazysite/layouts/studio/themes/draft/theme.json",      '{"name":"draft"}' );
put( "$tmp/lazysite/layouts/studio/themes/draft/assets/main.css", "body{}\n" );
put( "$tmp/lazysite/layouts/studio/layout.tt",                    "[% content %]\n" );
put( "$tmp/lazysite-assets/studio/live/main.css",                 "body{}\n" );

require Lazysite::Manager::Files;
require Lazysite::Manager::Themes;
require Lazysite::Auth::Acl;
$Lazysite::Manager::Common::DOCROOT      = $tmp;
$Lazysite::Manager::Files::DOCROOT       = $tmp;
$Lazysite::Manager::Files::LOCK_DIR      = "$tmp/lazysite/locks";
$Lazysite::Manager::Themes::DOCROOT      = $tmp;
$Lazysite::Manager::Themes::LAZYSITE_DIR = "$tmp/lazysite";
$Lazysite::Manager::Themes::auth_user    = 'themer';
$Lazysite::Auth::Acl::DOCROOT            = $tmp;
{ no warnings 'once'; $Lazysite::Auth::Acl::token_auth = 0 }

my $LIVE  = 'lazysite/layouts/studio/themes/live';
my $DRAFT = 'lazysite/layouts/studio/themes/draft';

sub refused {
    my ( $r, $label ) = @_;
    ok( !$r->{ok}, "$label: refused" ) or diag explain $r;
    is( $r->{kind}, 'active-artifact-refused', "$label: kind names the rule" );
    return $r;
}

subtest 'the pure rule' => sub {
    my $rule = \&Lazysite::Manager::Common::active_artifact_refusal;
    ok( $rule->( "$LIVE/assets/main.css", 'studio', 'live' ), 'active theme file: refused' );
    ok( $rule->( q{/} . "$LIVE/assets/main.css", 'studio', 'live' ), 'with a leading slash too' );
    ok( !$rule->( "$DRAFT/assets/main.css", 'studio', 'live' ), 'a non-active theme under the active layout: allowed' );
    ok( !$rule->( 'lazysite/layouts/other/themes/live/x.css', 'studio', 'live' ),
        'a theme with the same name under ANOTHER layout: allowed' );
    ok( $rule->( 'lazysite/layouts/studio/layout.tt', 'studio', 'live' ), 'the active layout\'s template: refused' );
    ok( $rule->( 'lazysite/layouts/studio', 'studio', 'live' ), 'the active layout directory: refused' );
    ok( !$rule->( 'lazysite/layouts/other/layout.tt', 'studio', 'live' ), 'a non-active layout: allowed' );
    ok( !$rule->( 'pages/about.md', 'studio', 'live' ), 'content: not this rule\'s business' );
    ok( !$rule->( "$LIVE/assets/main.css", '', '' ), 'no active pointers: nothing is being served, nothing is refused' );
};

subtest 'the refusal names the workflow, not a way round' => sub {
    my $msg = Lazysite::Manager::Common::active_artifact_refusal( "$LIVE/theme.json", 'studio', 'live' );
    like( $msg, qr/read-only on every surface/, 'says it is every surface, so the reader does not go looking for another' );
    like( $msg, qr/copy it/i,          'first step: copy' );
    like( $msg, qr/edit the copy/,     'second: edit the copy' );
    like( $msg, qr/activate the copy/, 'third: activate' );
    like( $msg, qr/copy_theme/,        'names the MCP verb' );
    like( $msg, qr/theme-copy/,        'and the control API action' );
    like( $msg, qr/Themes page/,       'and where a sysop clicks' );
    like( $msg, qr/activate_theme/,    'and the activation verb' );
    unlike( $msg, qr/switch the active theme first|edit a non-active one/,
        'the old two escapes within one surface are gone' );
    unlike( $msg, qr/WebDAV/, 'and it does not name a surface as the odd one out' );
};

subtest 'every write verb at the choke point refuses the active theme' => sub {
    refused( Lazysite::Manager::Files::action_save( "$LIVE/assets/main.css", 'themer', "body{color:red}\n", undef ), 'save' );
    is( do { local ( @ARGV, $/ ) = "$tmp/$LIVE/assets/main.css"; <> }, "body{}\n", 'and the served file is untouched' );
    refused( Lazysite::Manager::Files::action_save_binary( "$LIVE/assets/logo.png", 'themer', "\x89PNG" ), 'binary save' );
    refused( Lazysite::Manager::Files::action_delete( "$LIVE/assets/main.css", 'themer' ), 'delete' );
    ok( -f "$tmp/$LIVE/assets/main.css", 'and it is still there' );
    refused( Lazysite::Manager::Files::action_mkdir("$LIVE/fonts"), 'mkdir' );
    refused( Lazysite::Manager::Files::action_move( "$LIVE/assets/main.css", "$DRAFT/assets/moved.css", 'themer' ), 'move OUT of the active theme' );
    refused( Lazysite::Manager::Files::action_move( "$DRAFT/assets/main.css", "$LIVE/assets/in.css", 'themer' ), 'move INTO the active theme' );
    refused( Lazysite::Manager::Files::action_copy( "$DRAFT/assets/main.css", "$LIVE/assets/in.css", 'themer' ), 'copy INTO the active theme' );
    refused( Lazysite::Manager::Files::action_save( 'lazysite/layouts/studio/layout.tt', 'themer', "x\n", undef ), 'save into the active LAYOUT' );
};

subtest 'the same verbs into the non-active theme stay open - that is the workflow' => sub {
    my $r = Lazysite::Manager::Files::action_save( "$DRAFT/assets/main.css", 'themer', "body{color:blue}\n", undef );
    ok( $r->{ok}, 'save into the draft theme: allowed' ) or diag explain $r;
    $r = Lazysite::Manager::Files::action_copy( "$LIVE/assets/main.css", "$DRAFT/assets/from-live.css", 'themer' );
    ok( $r->{ok}, 'copy OUT of the active theme into the draft: allowed (reading the live theme is fine)' ) or diag explain $r;
    $r = Lazysite::Manager::Files::action_mkdir("$DRAFT/fonts");
    ok( $r->{ok}, 'mkdir in the draft: allowed' ) or diag explain $r;
};

subtest 'action_theme_copy is the first step, on one call' => sub {
    my $r = Lazysite::Manager::Themes::action_theme_copy( 'live', 'Live-Next' );
    ok( $r->{ok}, 'the active theme can be copied' ) or diag explain $r;
    is( $r->{name},   'live-next', 'the copy is named, lower-cased' );
    is( $r->{layout}, 'studio',    'under the active layout' );
    like( $r->{next}, qr/activate/, 'and the reply says what comes next' );
    ok( -f "$tmp/lazysite/layouts/studio/themes/live-next/assets/main.css", 'the files are copied' );
    ok( -f "$tmp/lazysite-assets/studio/live-next/main.css", 'and the asset mirror' );

    my $json = JSON::PP::decode_json( do { local ( @ARGV, $/ ) = "$tmp/lazysite/layouts/studio/themes/live-next/theme.json"; <> } );
    is( $json->{name},        'live-next', 'theme.json names the copy, not the source' );
    is( $json->{copied_from}, 'live',      'and says where it came from' );
    is_deeply( $json->{config}, { colours => { primary => '#000' } }, 'the design tokens travel' );

    my $conf = do { local ( @ARGV, $/ ) = "$tmp/lazysite/lazysite.conf"; <> };
    like( $conf, qr/^theme: live$/m, 'nothing changed on the live site - the pointer still names live' );

    # The copy is editable at once, through the same choke point that refused the source.
    my $w = Lazysite::Manager::Files::action_save( 'lazysite/layouts/studio/themes/live-next/assets/main.css', 'themer', "body{color:green}\n", undef );
    ok( $w->{ok}, 'the copy accepts a write' ) or diag explain $w;

    # The creator registry knows whose it is (delete_theme's rule).
    my $reg = Lazysite::Manager::Themes::_read_created_registry();
    is( $reg->{'studio/live-next'}, 'themer', 'the copier is recorded as the creator' );
};

subtest 'copy refusals are named' => sub {
    my $r = Lazysite::Manager::Themes::action_theme_copy( 'live', 'live-next' );
    ok( !$r->{ok}, 'a collision is refused' );
    is( $r->{kind}, 'exists', 'as exists' );
    $r = Lazysite::Manager::Themes::action_theme_copy( 'live', 'live' );
    ok( !$r->{ok} && $r->{kind} eq 'validation', 'a same-name copy is a validation refusal' );
    $r = Lazysite::Manager::Themes::action_theme_copy( 'nope', 'x' );
    is( $r->{kind}, 'not-found', 'a missing source is not-found' );
    $r = Lazysite::Manager::Themes::action_theme_copy( 'live', 'two', { layout => 'other' } );
    ok( $r->{ok}, 'a layout may be named explicitly' ) or diag explain $r;
    ok( -d "$tmp/lazysite/layouts/other/themes/two", 'and the copy lands under it' );
};

done_testing();
