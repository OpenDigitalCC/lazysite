#!/usr/bin/perl
# SM1191 (n680, test plan 0.15.10 F-5): "the app_* keys (app_name, app_scope,
# icons, colours) are in neither the config-set allow list nor the Config page,
# so an operator without shell cannot make a site an app."
#
# The engine turns the app OFF on a value it cannot honour (SM1155) and says
# nothing at serve time, so the save must refuse what the engine would refuse
# and NAME the key. The parity subtest runs the same values through config-set
# and through the engine's manifest and fails if they disagree.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use JSON::PP qw(encode_json decode_json);
use MIME::Base64 qw(encode_base64);
use File::Temp ();
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root grant_caps site_tempdir setup_test_site run_processor run_child);
use PageScript qw(page_source extract_function);

my $root  = repo_root();
my $utool = "$root/tools/lazysite-users.pl";
my $mapi  = "$root/lazysite-manager-api.pl";

sub uapi {
    my ( $d, $p ) = @_;
    my $out = run_child( [ $^X, $utool, '--api', '--docroot', $d ],
        stdin => encode_json($p), stderr => 'inherit' )->{out};
    return eval { decode_json($out) } // {};
}
sub mapi {
    my ( $d, %o ) = @_;
    my $body = delete $o{body};
    local %ENV = %ENV;
    $ENV{DOCUMENT_ROOT}  = $d;
    $ENV{REQUEST_METHOD} = $o{REQUEST_METHOD} || 'GET';
    $ENV{CONTENT_LENGTH} = defined $body ? length($body) : 0;
    delete $ENV{HTTP_X_REMOTE_USER};
    $ENV{$_} = $o{$_} for grep { defined $o{$_} } keys %o;
    my $out = run_child( [ $^X, $mapi ], stdin => ( defined $body ? $body : '' ) )->{out};
    my ($jb) = $out =~ /\r?\n\r?\n(.*)/s;
    return eval { decode_json( $jb // '' ) } // { _raw => $out };
}
sub basic { 'Basic ' . encode_base64( "$_[0]:$_[1]", '' ) }
sub conf  { open my $f, '<', "$_[0]/lazysite/lazysite.conf" or die $!; local $/; <$f> }

my $d = site_tempdir();
setup_test_site($d);
open my $cf, '>>', "$d/lazysite/lazysite.conf" or die $!;
print $cf "control_api_enabled: true\n"; close $cf;
make_path("$d/assets");
for my $f (qw(lazysite-chrome.css lazysite-chrome.js lazysite-app.js)) {
    open my $o, '>', "$d/assets/$f" or die $!; print {$o} "/* $f */\n"; close $o;
}
make_path("$d/portal");
open my $pg, '>', "$d/portal/index.md" or die $!;
print {$pg} "---\ntitle: Portal\n---\nPortal page.\n"; close $pg;
make_path("$d/icons");
open my $ic, '>', "$d/icons/a-192.png" or die $!; binmode $ic; print {$ic} "\x89PNG\r\n"; close $ic;

uapi( $d, { action => 'add', username => 'p', password => 'x-long-enough' } );
grant_caps( $d, 'p', 'manage_config', 'api' );
my $tok = uapi( $d, { action => 'token', username => 'p' } )->{token};
ok( $tok && $tok =~ /^lzs_/, 'minted a manage_config token' );

sub set {
    my ( $k, $v ) = @_;
    return mapi( $d, REQUEST_METHOD => 'POST', QUERY_STRING => 'action=config-set',
        HTTP_AUTHORIZATION => basic( 'p', $tok ),
        body => encode_json( { key => $k, value => $v } ) );
}
sub manifest {
    my ($uri) = @_;
    my $out = run_processor( $d, $uri );
    my ( $head, $body ) = split /\r?\n\r?\n/, $out, 2;
    return ( ( $head // '' ) =~ /Status:\s*(\d{3})/i )[0] // '200', $body // '';
}

subtest 'config-set app_name and app_scope, and the manifest serves them' => sub {
    my ($st0) = manifest('/portal/manifest.webmanifest');
    is( $st0, '404', 'no app before' );
    ok( set( app_name  => 'Pocket Portal' )->{ok}, 'app_name is accepted' );
    ok( set( app_scope => '/portal/' )->{ok},      'app_scope is accepted' );
    ok( set( app_icon_192 => '/icons/a-192.png' )->{ok}, 'an icon that exists is accepted' );
    ok( set( app_theme_colour => '#0a5c36' )->{ok}, 'a colour is accepted' );
    like( conf($d), qr/^app_scope: \/portal\/$/m, 'written to lazysite.conf' );
    my ( $st, $body ) = manifest('/portal/manifest.webmanifest');
    is( $st, '200', 'the manifest is served under the scope' );
    my $m = eval { decode_json($body) } || {};
    is( $m->{name},        'Pocket Portal', 'with the name set' );
    is( $m->{scope},       '/portal/',      'and the scope set' );
    is( $m->{theme_color}, '#0a5c36',       'and the colour set' );
    is( $m->{icons}[0]{src}, '/icons/a-192.png', 'and the icon set' );
};

subtest 'a value the engine would turn the app off for is refused, naming the key' => sub {
    my %bad = (
        app_scope        => [ 'portal',         'no slashes' ],
        app_scope2       => [ '/a/../b/',       'dot-dot' ],
        app_start_url    => [ '/elsewhere/',    'outside the scope' ],
        app_icon_512     => [ '/icons/no.png',  'a file the site does not serve' ],
        app_icon_64      => [ '/icons/x.exe',   'not an image path' ],
        app_theme_colour => [ 'green',          'not #rgb or #rrggbb' ],
        app_background_colour => [ '#12', 'too short' ],
    );
    for my $k ( sort keys %bad ) {
        my ( $v, $why ) = @{ $bad{$k} };
        ( my $key = $k ) =~ s/2\z//;
        my $r = set( $key => $v );
        ok( !$r->{ok}, "$key refused ($why)" );
        like( $r->{error} // '', qr/\b\Q$key\E\b/, '... and the refusal names the key' );
        unlike( conf($d), qr/^\Q$key\E: \Q$v\E$/m, '... and nothing was written' );
    }
};

subtest 'a start page must sit inside the stored scope' => sub {
    ok( set( app_start_url => '/portal/home?x=1' )->{ok}, 'inside the scope: accepted' );
    my $r = set( app_scope => '/other/' );
    ok( !$r->{ok}, 'a scope that leaves the stored start page outside is refused' );
    like( $r->{error} // '', qr/app_start_url/, '... naming the start page to change first' );
    ok( set( app_start_url => '' )->{ok}, 'a start page can be cleared' );
    ok( set( app_scope => '/other/' )->{ok}, 'then the scope moves' );
    ok( set( app_scope => '/portal/' )->{ok}, 'and back' );
};

subtest 'every app key can be cleared (clearing app_name turns the app off)' => sub {
    for my $k (qw(app_short_name app_theme_colour app_background_colour app_icon_192 app_icon_64
        app_icon_512 app_icon_maskable app_shell app_start_url app_scope app_name)) {
        ok( set( $k => '' )->{ok}, "$k clears" );
    }
    my ($st) = manifest('/portal/manifest.webmanifest');
    is( $st, '404', 'the app is off again' );
};

subtest 'app_shell and app_short_name are checked' => sub {
    ok( set( app_shell => '/assets/a.css, /assets/b.js' )->{ok}, 'a list of site paths' );
    my $r = set( app_shell => '/assets/../etc/passwd' );
    ok( !$r->{ok}, 'a path with .. is refused' );
    like( $r->{error} // '', qr/app_shell/, '... naming the key' );
    $r = set( app_shell => 'assets/a.css' );
    ok( !$r->{ok}, 'a path that does not start with / is refused' );
    ok( set( app_short_name => 'Portal' )->{ok}, 'a short name' );
    ok( !set( app_short_name => "a\nb" )->{ok}, 'a newline is refused' );
};

subtest 'parity: what config-set refuses is what the engine would not honour' => sub {
    # The same value written straight into the conf (as an operator on the host
    # could) and read by the engine. Scope and start page: the app goes OFF.
    # Colour and icon: the engine leaves the value out of the manifest.
    my $keep = conf($d);
    my $try = sub {
        my ( $extra, $uri ) = @_;
        open my $o, '>', "$d/lazysite/lazysite.conf" or die $!;
        print {$o} $keep, "app_name: Parity\n", $extra;
        close $o;
        my ( $st, $body ) = manifest($uri);
        return ( $st, eval { decode_json($body) } || {} );
    };
    my ($st) = $try->( "app_scope: portal\n", '/manifest.webmanifest' );
    is( $st, '404', 'engine: a scope with no slashes turns the app off' );
    ($st) = $try->( "app_scope: /portal/\napp_start_url: /elsewhere/\n", '/portal/manifest.webmanifest' );
    is( $st, '404', 'engine: a start page outside the scope turns the app off' );
    my ( undef, $m ) = $try->( "app_icon_512: /icons/no.png\napp_icon_192: /icons/a-192.png\n", '/manifest.webmanifest' );
    is_deeply( [ map { $_->{src} } @{ $m->{icons} || [] } ], ['/icons/a-192.png'],
        'engine: an icon the site does not serve is left out' );
    ( undef, $m ) = $try->( "app_theme_colour: green\n", '/manifest.webmanifest' );
    ok( !exists $m->{theme_color}, 'engine: a colour that is not #rgb or #rrggbb is left out' );
    open my $o, '>', "$d/lazysite/lazysite.conf" or die $!; print {$o} $keep; close $o;
    # ...and the very same values are refused at save (the subtests above), so a
    # save and the engine cannot disagree about what is honoured.
    ok( !set( app_scope => 'portal' )->{ok}, 'config-set refuses the scope' );
    ok( !set( app_icon_512 => '/icons/no.png' )->{ok}, 'config-set refuses the icon' );
    ok( !set( app_theme_colour => 'green' )->{ok}, 'config-set refuses the colour' );
};

subtest 'config-read surfaces them, so the page shows what is set' => sub {
    set( app_name => 'Shown' );
    my $r = mapi( $d, QUERY_STRING => 'action=config-read', HTTP_AUTHORIZATION => basic( 'p', $tok ) );
    is( $r->{config}{app_name}, 'Shown', 'app_name read back' );
    ok( exists $r->{config}{app_icon_maskable}, 'and the other keys are in the read' );
    set( app_name => '' );
};

subtest 'the Config page offers the section' => sub {
    my $src = page_source("$root/starter/manager/config.md");
    my $js  = join "\n",
        ( $src =~ /(var SITE_SCHEMA = \[.*?\n\];)/s )[0] // die('no SITE_SCHEMA'),
        ( $src =~ /(var SERVICE_PRESETS = \{.*?\n\};)/s )[0] // die('no presets'),
        extract_function( $src, 'esc' ),
        extract_function( $src, 'renderSiteForm' );
    my $t = File::Temp->new( SUFFIX => '.js' );
    print {$t} "var availableLayouts = [];\nvar location = {protocol:'https:',host:'x'};\n$js\n"
        . "console.log(JSON.stringify({html: renderSiteForm({app_name:'Mine'}), keys: SITE_SCHEMA.map(function(f){return f.key})}));\n";
    close $t;
    my $node = `sh -c 'command -v node || command -v nodejs' 2>/dev/null`; chomp $node;
    plan skip_all => 'node not installed' unless length $node;
    my $out = `\Q$node\E \Q$t\E 2>&1`;
    my $got = eval { decode_json($out) } or BAIL_OUT("page script did not run: $out");
    like( $got->{html}, qr/Install as an app/, 'the section is headed "Install as an app"' );
    for my $k (qw(app_name app_short_name app_scope app_start_url app_theme_colour app_background_colour
        app_icon_64 app_icon_192 app_icon_512 app_icon_maskable app_shell)) {
        ok( ( grep { $_ eq $k } @{ $got->{keys} } ), "$k is a field" );
        like( $got->{html}, qr/name="\Q$k\E"/, "$k is rendered" );
    }
    like( $got->{html}, qr/value="Mine"/, 'with the stored value' );
    like( $got->{html}, qr/mg-config-help[^>]*>[^<]*scope/i, 'and a note for the scope' );
};

done_testing();
