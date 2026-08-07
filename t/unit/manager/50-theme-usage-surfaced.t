#!/usr/bin/perl
# SM234: the theme/layout listings must report which registered domains resolve
# to each one. The SM177 delete guard already refuses a theme a domain depends on
# and names the domains; the LISTING did not know, so the manager offered a
# Delete button and the operator learned it was protected only from the error
# that came back.
#
# The listing and the guard must agree, so this pins domain_usage (the one-parse
# inverse map the listings consume) against domains_using (what the guard asks),
# including the case that motivated it: an alias inheriting the active layout
# while pinning its own theme.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../../lib";
use Lazysite::Manager::Domains ();
use Lazysite::Manager::Themes  ();

my $d = tempdir( CLEANUP => 1 );
make_path("$d/lazysite/layouts/base/themes/$_") for qw(house client spare);
make_path("$d/lazysite/layouts/other/themes/legacy");
for my $p ( qw(base/themes/house base/themes/client base/themes/spare
    other/themes/legacy) )
{
    open my $t, '>', "$d/lazysite/layouts/$p/theme.json" or die $!;
    print {$t} '{"name":"x"}';
    close $t;
}

# The default site runs base/house. clienta pins base/client. alias.clientb
# inherits the active LAYOUT but pins its own theme - the case the guard was
# written for. nothing uses base/spare or other/legacy.
open my $c, '>', "$d/lazysite/lazysite.conf" or die $!;
print {$c} <<'CONF';
site_name: T
layout: base
theme: house
alias_hosts: clienta.example, clientb.example
alias.clienta.example.layout: base
alias.clienta.example.theme: client
alias.clientb.example.theme: client
CONF
close $c;

$Lazysite::Manager::Domains::DOCROOT = $d;
$Lazysite::Manager::Themes::DOCROOT  = $d;

my $use = Lazysite::Manager::Domains::domain_usage();

is_deeply( [ sort @{ $use->{themes}{"base\0house"} } ], ['(default)'],
    'the site-wide theme is used by the default site' );
is_deeply( [ sort @{ $use->{themes}{"base\0client"} } ],
    [ 'clienta.example', 'clientb.example' ],
    'a theme pinned by two domains names both - including the alias that '
        . 'inherits the layout and pins only the theme' );
ok( !exists $use->{themes}{"base\0spare"}, 'an unused theme has no usage entry' );
is_deeply( [ sort @{ $use->{layouts}{base} } ],
    [ '(default)', 'clienta.example', 'clientb.example' ],
    'layout usage covers the default site and every domain resolving to it' );
ok( !exists $use->{layouts}{other}, 'an unused layout has no usage entry' );

# The listing must carry the same answer the guard gives, or the UI would offer
# a Delete the server then refuses (the reported defect) - or worse, hide a
# Delete that would have worked.
my $listed = Lazysite::Manager::Themes::action_theme_list();
my %by = map { $_->{name} => $_ } @{ $listed->{themes} };

is_deeply( [ sort @{ $by{client}{used_by} } ],
    [ 'clienta.example', 'clientb.example' ],
    'action_theme_list reports the domains using a theme' );
ok( $by{client}{in_use}, 'and marks it in use' );
ok( !$by{client}{active}, 'though it is NOT the site-wide active theme' );
ok( !$by{spare}{in_use}, 'an unused theme is not marked in use' );
is_deeply( $by{spare}{used_by}, [], 'and names nobody' );

for my $t (qw(client spare)) {
    my @guard = Lazysite::Manager::Domains::domains_using(
        theme => $t, layout => 'base' );
    is_deeply( [ sort @{ $by{$t}{used_by} } ], [ sort @guard ],
        "listing agrees with the delete guard for '$t'" );
}

done_testing();
