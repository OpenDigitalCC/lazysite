#!/usr/bin/perl
# DM-1: the Data tables nav entry, gated on TWO things at once.
#
# It is the first menu item that needs both a PLUGIN to be enabled and a
# CAPABILITY to be held, and the two answer different questions:
#
#   the plugin off      -> the feature is not installed on this site
#   the capability off  -> the feature is here and is not yours
#
# Showing a padlocked hint for a plugin nobody has enabled would advertise a
# feature that does not exist; hiding the item from a manager who could simply
# grant themselves the capability would leave them with no way to discover it.
# So the plugin gate is OUTSIDE and silent, and the capability gate is INSIDE
# and speaks.
#
# Rendered through the real layout, as the domains and enabled_plugins nav
# tests are. Sabotage found the gap this file fills: with only the guide lint
# in place, the nav item could lose its capability gate, or point at an
# entirely different URL, and nothing failed.
use strict;
use warnings;
use Test::More;
use Template;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);

my $root   = repo_root();
my $layout = "$root/starter/lazysite/manager/layout.tt";
ok( -f $layout, 'manager layout present' ) or BAIL_OUT('no layout to render');

sub render {
    my (%extra) = @_;
    my $tt  = Template->new( ABSOLUTE => 1, EVAL_PERL => 0 );
    my $out = '';
    $tt->process(
        $layout,
        {   page_title      => 'Files',
            site_name       => 'Demo',
            request_uri     => '/manager/files',
            enabled_plugins => {},
            auth_user       => 'me',
            manager_caps    => {},
            %extra,
        },
        \$out
    ) or diag( $tt->error );
    return $out;
}

subtest 'the plugin decides whether the feature exists here' => sub {
    my $off = render(
        enabled_plugins => {},
        manager_caps    => { manage_data => 1, manage_users => 1 },
    );
    unlike( $off, qr{/manager/data\b}, 'plugin disabled: no Data tables link' );
    unlike( $off, qr/Data tables/, 'and no padlocked hint either' )
        or diag( 'A hint for a plugin nobody enabled advertises a feature the '
            . 'site does not have, and sends an operator to the Groups page '
            . 'to grant something that would still do nothing.' );

    my $on = render(
        enabled_plugins => { data => 1 },
        manager_caps    => { manage_data => 1 },
    );
    like( $on, qr{href="/manager/data"}, 'plugin enabled + capability: the link' );
};

subtest 'the capability decides whether it is yours' => sub {
    # A manager who can grant capabilities sees the padlocked hint naming the
    # grant - the same treatment Files, Navigation and Domains get, so an
    # administrator can tell "not permitted" from "not installed".
    my $hint = render(
        enabled_plugins => { data => 1 },
        manager_caps    => { manage_data => 0, manage_users => 1 },
    );
    like( $hint, qr/Data tables &#128274;/, 'grant-capable user sees the lock' );
    like( $hint, qr/grant 'Data'/, 'and is told which grant enables it' );
    unlike( $hint, qr{href="/manager/data"},
        'the hint is NOT a link to the gated page' )
        or diag( 'A link that refuses when followed teaches an operator to '
            . 'distrust the menu.' );

    # Someone who cannot grant it gets nothing: a hint is pointless to a person
    # who cannot act on it.
    my $plain = render(
        enabled_plugins => { data => 1 },
        manager_caps    => { manage_data => 0, manage_users => 0 },
    );
    unlike( $plain, qr/Data tables/, 'a non-granting user sees no entry at all' );
};

subtest 'it does not disturb the rest of the menu' => sub {
    my $on = render(
        enabled_plugins => { data => 1 },
        manager_caps    => { manage_data => 1 },
    );
    like( $on, qr{/manager/cache},   'Cache is still there' );
    like( $on, qr{/manager/plugins}, 'and the Plugin Manager' );
};

done_testing();
