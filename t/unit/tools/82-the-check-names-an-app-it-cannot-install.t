#!/usr/bin/perl
# SM1155: `lazysite check` says so when a site declares an app the engine cannot
# honour (it turns the app off, it does not guess), and when an icon the settings
# name is not a file the site serves (the manifest leaves it out).
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root site_tempdir);

my $tool = repo_root() . '/tools/lazysite-check.pl';
plan skip_all => "no $tool" unless -f $tool;

sub site {
    my ( $conf, @icons ) = @_;
    my $d = site_tempdir();
    make_path("$d/lazysite");
    open my $fh, '>', "$d/lazysite/lazysite.conf" or die $!;
    print {$fh} "site_name: T\n$conf";
    close $fh;
    for my $i (@icons) {
        make_path( "$d" . ( $i =~ s{/[^/]+\z}{}r ) );
        open my $o, '>', "$d$i" or die $!;
        close $o;
    }
    return $d;
}

sub run {
    my ($d) = @_;
    open my $fh, '-|', $^X, $tool, '--docroot', $d or return '';
    my $out = do { local $/; <$fh> };
    close $fh;
    return $out // '';
}

unlike( run( site('') ), qr/\bapp\b.*(?:OFF|icon)/, 'no app_name: nothing said' );

my $ok = run( site( "app_name: P\napp_icon_192: /i/192.png\napp_icon_512: /i/512.png\n", '/i/192.png', '/i/512.png' ) );
like( $ok, qr/app 'P' is declared at \//, 'a valid app is reported OK' );
unlike( $ok, qr/is OFF|leaves out|names no icons/, 'and nothing is warned' );

my $off = run( site( "app_name: P\napp_scope: portal\napp_icon_192: /i/192.png\n", '/i/192.png' ) );
like( $off, qr/the app is OFF: app_scope \(portal\) must start and end with \//, 'a bad scope names the value and says the app is off' );

my $out = run( site( "app_name: P\napp_scope: /portal/\napp_start_url: /elsewhere\napp_icon_192: /i/192.png\n", '/i/192.png' ) );
like( $out, qr/app_start_url \(\/elsewhere\) must be a path inside app_scope \(\/portal\/\)/, 'a start page outside the scope is named' );

my $miss = run( site( "app_name: P\napp_icon_192: /i/192.png\napp_icon_512: /i/512.png\n", '/i/192.png' ) );
like( $miss, qr{leaves out 1 icon\(s\).*app_icon_512 \(/i/512\.png\)}, 'an icon the site does not serve is named' );

my $none = run( site("app_name: P\n") );
like( $none, qr/names no icons/, 'no icons named: said, with the keys to set' );

my $col = run( site( "app_name: P\napp_theme_colour: green\napp_icon_192: /i/a.png\n", '/i/a.png' ) );
like( $col, qr/app_theme_colour \(green\) must be #rgb or #rrggbb/, 'a colour that is not a hex colour is named' );

done_testing();
