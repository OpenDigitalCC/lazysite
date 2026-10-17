#!/usr/bin/perl
# SM1155 (L1, 2026-10-17): a site, or a section of it, installs as an app. The
# engine generates the manifest and the service worker from the app_* settings;
# nothing is authored under /lazysite-assets/.
#
# Asked and ruled: both levels (scope / and a scope under a path); icons from
# site files named in the settings, left out when absent; a worker whose cache
# name follows the engine release and a fingerprint of the shell, so a deploy
# reaches installed devices; the manifest and worker ABSENT when the feature is
# off. What the worker refuses is t/unit/processor/134.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use JSON::PP   qw(decode_json);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(site_tempdir setup_test_site run_processor);

sub site {
    my ($conf) = @_;
    my $d = site_tempdir();
    setup_test_site($d);
    open my $fh, '>>', "$d/lazysite/lazysite.conf" or die $!;
    print {$fh} $conf;
    close $fh;
    make_path("$d/assets");
    for my $f (qw(lazysite-chrome.css lazysite-chrome.js lazysite-app.js)) {
        open my $o, '>', "$d/assets/$f" or die $!;
        print {$o} "/* $f */\n";
        close $o;
    }
    make_path("$d/portal");
    open my $p, '>', "$d/portal/index.md" or die $!;
    print {$p} "---\ntitle: Portal\n---\nPortal page.\n";
    close $p;
    return $d;
}

sub icon {
    my ( $d, $name ) = @_;
    make_path("$d/icons");
    open my $o, '>', "$d/icons/$name" or die $!;
    binmode $o;
    print {$o} "\x89PNG\r\n";
    close $o;
}

sub get {
    my ( $d, $uri ) = @_;
    my $out = run_processor( $d, $uri );
    my ( $head, $body ) = split /\r?\n\r?\n/, $out, 2;
    my %h;
    for ( split /\r?\n/, $head // '' ) { $h{ lc $1 } = $2 if /^([^:]+):\s*(.*)$/ }
    return { h => \%h, body => $body // '', status => ( ( $h{status} // '' ) =~ /^(\d{3})/ )[0] // '' };
}

my $ON = "app_name: Pocket Portal\napp_short_name: Portal\napp_theme_colour: #0a5c36\n"
    . "app_icon_192: /icons/a-192.png\napp_icon_512: /icons/a-512.png\n";

subtest 'off: no manifest, no worker, no link on a page' => sub {
    my $d = site('');
    is( get( $d, '/manifest.webmanifest' )->{status}, '404', 'no manifest' );
    is( get( $d, '/lazysite-sw.js' )->{status},       '404', 'no worker' );
    unlike( get( $d, '/' )->{body}, qr/manifest|lazysite-app\.js/, 'and the page carries neither' );
};

subtest 'site level: the manifest comes from the settings' => sub {
    my $d = site($ON);
    icon( $d, 'a-192.png' );
    icon( $d, 'a-512.png' );
    my $r = get( $d, '/manifest.webmanifest' );
    is( $r->{status}, '200', 'served' );
    like( $r->{h}{'content-type'}, qr{\Aapplication/manifest\+json\b}, 'as a manifest' );
    my $m = decode_json( $r->{body} );
    is( $m->{name},        'Pocket Portal', 'name' );
    is( $m->{short_name},  'Portal',        'short name' );
    is( $m->{scope},       '/',             'scope is the site' );
    is( $m->{start_url},   '/',             'start is the scope by default' );
    is( $m->{theme_color}, '#0a5c36',       'theme colour' );
    is( $m->{display},     'standalone',    'standalone' );
    is_deeply( [ map { $_->{src} } @{ $m->{icons} } ], [ '/icons/a-192.png', '/icons/a-512.png' ], 'the icons named' );
    is( $m->{icons}[0]{sizes}, '192x192', 'with their sizes' );
};

subtest 'section level: a scope under a path, the documents live inside it' => sub {
    my $d = site( $ON . "app_scope: /portal/\napp_start_url: /portal/\n" );
    my $r = get( $d, '/portal/manifest.webmanifest' );
    is( $r->{status}, '200', 'the manifest is under the scope' );
    is( decode_json( $r->{body} )->{scope}, '/portal/', 'scope' );
    is( get( $d, '/manifest.webmanifest' )->{status}, '404', 'and not at the root' );
    my $w = get( $d, '/portal/lazysite-sw.js' );
    is( $w->{status}, '200', 'the worker is under the scope' );
    like( $w->{h}{'content-type'}, qr{\Atext/javascript\b}, 'as JavaScript' );
    ok( !exists $w->{h}{'service-worker-allowed'}, 'no Service-Worker-Allowed: the worker is inside its scope' );
    like( $w->{h}{'cache-control'}, qr/no-cache/, 'and a deploy is seen on the next check' );

    my $in  = get( $d, '/portal/' )->{body};
    like( $in, qr{<link rel="manifest" href="/portal/manifest\.webmanifest">}, 'a page in the scope links the manifest' );
    like( $in, qr{data-ls-app-sw="/portal/lazysite-sw\.js"}, 'and registers the worker' );
    like( $in, qr{data-ls-app-scope="/portal/"}, 'for that scope' );
    unlike( get( $d, '/' )->{body}, qr/manifest|lazysite-app\.js/, 'a page outside the scope carries neither' );
};

subtest 'a wrong declaration turns the app off, not into a guess' => sub {
    for my $bad ( "app_scope: portal\n", "app_scope: /a/../b/\n", "app_scope: /portal/\napp_start_url: /elsewhere\n" ) {
        my $d = site( "app_name: X\n$bad" );
        ( my $what = $bad ) =~ s/\n/ /g;
        is( get( $d, '/manifest.webmanifest' )->{status}, '404', "off for: $what" );
    }
};

subtest 'icons are validated present; an absent one is left out' => sub {
    my $d = site($ON);
    icon( $d, 'a-192.png' );    # the 512 is named and missing
    my $m = decode_json( get( $d, '/manifest.webmanifest' )->{body} );
    is_deeply( [ map { $_->{src} } @{ $m->{icons} } ], ['/icons/a-192.png'], 'only the file that is there' );

    my $none = site("app_name: Bare\n");
    my $b    = decode_json( get( $none, '/manifest.webmanifest' )->{body} );
    ok( !exists $b->{icons}, 'no icons named, no icons key' );
    ok( !exists $b->{theme_color}, 'no colour set, none emitted' );

    my $mk = site( $ON . "app_icon_maskable: /icons/m.png\n" );
    icon( $mk, 'a-192.png' );
    icon( $mk, 'm.png' );
    my @i = @{ decode_json( get( $mk, '/manifest.webmanifest' )->{body} )->{icons} };
    is_deeply( [ map { $_->{purpose} } @i ], [ 'any', 'maskable' ], 'the maskable one says so' );
};

subtest 'the worker follows the release and the shell' => sub {
    my $d = site($ON);
    my $w1 = get( $d, '/lazysite-sw.js' )->{body};
    my ($c1) = $w1 =~ /"cache":"([^"]+)"/;
    like( $c1, qr/\Alazysite-app-.+-[0-9a-f]{12}\z/, 'the cache name carries a release and a fingerprint' );
    is( ( get( $d, '/lazysite-sw.js' )->{body} =~ /"cache":"([^"]+)"/ )[0], $c1, 'and is stable while nothing changes' );

    # a deploy that changes a shell file
    my $css = "$d/assets/lazysite-chrome.css";
    open my $o, '>', $css or die $!;
    print {$o} "/* a different stylesheet, longer */\n";
    close $o;
    utime 1_700_000_000, 1_700_000_000, $css;
    my ($c2) = get( $d, '/lazysite-sw.js' )->{body} =~ /"cache":"([^"]+)"/;
    isnt( $c2, $c1, 'a changed shell file changes the worker' );

    # a new engine release
    make_path("$d/lazysite");
    open my $s, '>', "$d/lazysite/.install-state.json" or die $!;
    print {$s} '{"version":"9.9.9"}';
    close $s;
    my ($c3) = get( $d, '/lazysite-sw.js' )->{body} =~ /"cache":"([^"]+)"/;
    like( $c3, qr/\Alazysite-app-9\.9\.9-/, 'the release is in the name' );
    isnt( $c3, $c2, 'a new release changes the worker' );
};

subtest 'the shell names the engine files, the icons and the start page theme files, never an endpoint' => sub {
    my $d = site( $ON . "app_shell: /themes/site.css, /cgi-bin/lazysite-odoo.pl, /manager/x.js, /login/y.js\n" );
    icon( $d, 'a-192.png' );
    icon( $d, 'a-512.png' );
    # the start page's cached render links the theme's files
    open my $o, '>', "$d/index.html" or die $!;
    print {$o} '<html><head><link rel="stylesheet" href="/lazysite-assets/l/t/theme.css?v=3"></head>'
        . '<body><script src="/lazysite-assets/l/t/theme.js"></script><script src="https://cdn.example.com/x.js"></script>'
        . '<script src="/cgi-bin/lazysite-odoo.pl"></script></body></html>';
    close $o;
    my $w = get( $d, '/lazysite-sw.js' )->{body};
    my ($shell) = $w =~ /"shell":(\[[^\]]*\])/;
    my @s = @{ decode_json($shell) };
    for my $want (qw(/assets/lazysite-chrome.css /assets/lazysite-chrome.js /assets/lazysite-app.js
        /icons/a-192.png /themes/site.css /lazysite-assets/l/t/theme.css?v=3 /lazysite-assets/l/t/theme.js))
    {
        ok( ( grep { $_ eq $want } @s ), "shell has $want" );
    }
    is( scalar( grep { m{cgi-bin|manager|login|cdn\.example} } @s ), 0, 'and no endpoint, manager, sign-in or other origin' );
};

done_testing();
