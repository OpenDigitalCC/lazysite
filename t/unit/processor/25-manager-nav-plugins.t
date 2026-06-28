#!/usr/bin/perl
# The manager layout shows the "Visitor statistics" nav item (sidebar + command
# palette) only when the stats plugin is enabled, driven by the enabled_plugins
# var the processor passes. Regression for the item disappearing while enabled.
use strict;
use warnings;
use Test::More;
use Template;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);

my $root   = repo_root();
my $layout = "$root/starter/lazysite/manager/layout.tt";
ok( -f $layout, 'manager layout present' );

sub render {
    my ($enabled) = @_;
    my $tt = Template->new( ABSOLUTE => 1, EVAL_PERL => 0 );
    my $out = '';
    $tt->process( $layout, {
        page_title       => 'Files',
        site_name        => 'Demo',
        request_uri      => '/manager/files',
        enabled_plugins  => $enabled,
        manager_groups   => 'admin',
        auth_user        => 'me',
        user_groups      => ['admin'],
        content          => 'BODY',
        year             => 2026,
        lazysite_version => '0.0.0',
    }, \$out ) or die "TT error: " . $tt->error();
    return $out;
}

# enabled_plugins keyed by the extensionless id (stats), as the processor builds.
my $on = render( { 'stats.pl' => 1, 'stats' => 1 } );
like( $on, qr{/manager/stats}, 'enabled: stats nav link present' );
like( $on, qr{Visitor statistics}, 'enabled: stats nav label present' );

my $off = render( {} );
unlike( $off, qr{/manager/stats}, 'disabled: no stats nav link' );
unlike( $off, qr{Visitor statistics}, 'disabled: no stats nav label' );

# The rest of the nav is unaffected either way.
like( $off, qr{/manager/files}, 'other nav items still present when stats off' );

done_testing;
