#!/usr/bin/perl
# SM177: sub-domains are first-class peers in theme delete-safety. A theme a
# registered domain uses (under the active layout, where the theme lives) must
# not be deletable out from under it - and domains_using resolves each host's
# EFFECTIVE theme/layout so an alias that inherits the base layout but pins its
# own theme is caught.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use JSON::PP qw(encode_json);
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);
use Lazysite::Manager::Domains qw(domains_using);

my $root    = repo_root();
my $docroot = tempdir( CLEANUP => 1 );
make_path("$docroot/lazysite");

sub set_conf {
    open my $c, '>', "$docroot/lazysite/lazysite.conf" or die $!;
    print $c $_[0];
    close $c;
}

sub write_layout_theme {
    my ( $layout, $theme ) = @_;
    my $tdir = "$docroot/lazysite/layouts/$layout/themes/$theme";
    make_path($tdir);
    open my $lf, '>', "$docroot/lazysite/layouts/$layout/layout.tt" or die $!;
    print $lf "<html>[% content %]</html>\n";
    close $lf;
    open my $tj, '>', "$tdir/theme.json" or die $!;
    print $tj encode_json(
        { name => $theme, version => '1.0', layouts => [$layout], config => {} } );
    close $tj;
    my $mir = "$docroot/lazysite-assets/$layout/$theme";
    make_path($mir);
    open my $css, '>', "$mir/main.css" or die $!;
    print $css "x{}\n";
    close $css;
}

# --- domains_using: effective resolution, sub-domains first-class -------------
$Lazysite::Manager::Domains::DOCROOT = $docroot;
set_conf( <<'CONF' );
layout: base
theme: default
alias_hosts: a.example, b.example, c.example
alias.a.example.theme: ocean
alias.b.example.layout: promo
alias.b.example.theme: ocean
alias.c.example.site_name: C
CONF

# ocean under the ACTIVE layout (base): a.example pins it; c.example inherits the
# base theme (default), NOT ocean; b.example uses ocean but under layout 'promo'.
is_deeply( [ domains_using( theme => 'ocean', layout => 'base' ) ], ['a.example'],
    'theme users are resolved under the given layout only' );
is_deeply( [ domains_using( theme => 'ocean', layout => 'promo' ) ], ['b.example'],
    'the same theme name under a different layout is a different user set' );
is_deeply( [ domains_using( theme => 'default', layout => 'base' ) ],
    [ '(default)', 'c.example' ],
    'the primary and an inheriting sub-domain both use the base theme' );
is_deeply( [ domains_using( layout => 'promo' ) ], ['b.example'],
    'layout users include a sub-domain that pins the layout' );
is_deeply( [ domains_using( layout => 'base' ) ],
    [ '(default)', 'a.example', 'c.example' ],
    'layout users include the primary and every inheriting sub-domain' );

# --- the theme-delete action honours the scan --------------------------------
BEGIN {
    $ENV{LAZYSITE_API_LOAD_ONLY} = 1;
    $ENV{DOCUMENT_ROOT}          = '/tmp';
}
{
    local $ENV{DOCUMENT_ROOT} = $docroot;
    package main;
    do "$root/lazysite-manager-api.pl" or die "load failed: $@";
}

# Active layout base with themes default (active) + ocean; a.example pins ocean.
write_layout_theme( 'base', 'default' );
write_layout_theme( 'base', 'ocean' );
set_conf( <<'CONF' );
layout: base
theme: default
alias_hosts: a.example
alias.a.example.theme: ocean
CONF

subtest 'theme-delete refused while a sub-domain uses the theme' => sub {
    my $r = main::action_theme_delete('ocean');
    ok( !$r->{ok}, 'refused' );
    like( $r->{error}, qr/in use by/i,  'error says in use' );
    like( $r->{error}, qr/a\.example/,  'error names the sub-domain' );
    ok( -d "$docroot/lazysite/layouts/base/themes/ocean", 'theme still present' );
};

subtest 'theme-delete succeeds once no domain uses it' => sub {
    set_conf("layout: base\ntheme: default\n");    # drop the sub-domain
    my $r = main::action_theme_delete('ocean');
    ok( $r->{ok}, 'deleted' ) or diag explain $r;
    ok( !-d "$docroot/lazysite/layouts/base/themes/ocean", 'theme dir gone' );
};

done_testing;
