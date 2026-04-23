#!/usr/bin/perl
# SM069: admin-bar rendering. Pins the post-SM069 shape:
# - Manager tools still emitted for managers (Manage/Edit/Sign out)
# - Theme switcher (<select id="ls-theme-sel">) NEVER emitted
# - Admin bar skipped entirely for non-managers
# - Admin bar skipped on /manager/* URLs regardless
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(load_processor setup_minimal_site);

my $docroot = tempdir( CLEANUP => 1 );
setup_minimal_site($docroot);

# The admin bar checks lazysite.conf for manager: enabled + reads
# manager_groups. Set both so _is_manager returns true for the
# simulated auth in the manager-view tests below.
open my $cf, '>>', "$docroot/lazysite/lazysite.conf" or die $!;
print $cf "manager: enabled\n";
print $cf "manager_groups: admins\n";
close $cf;

load_processor($docroot);

sub html_with_body {
    return '<!doctype html><html><body>PAGE</body></html>';
}

# --- Non-manager visitor: entire admin bar suppressed ---

subtest 'non-manager visitor: no admin bar at all' => sub {
    local $ENV{HTTP_X_REMOTE_USER}   = '';
    local $ENV{HTTP_X_REMOTE_GROUPS} = '';
    my $vars = {
        manager       => 'enabled',
        manager_path  => '/manager',
        request_uri   => '/about',
        page_source   => '/about.md',
        auth_user     => '',
        auth_name     => '',
    };
    my $out = main::_inject_admin_bar( html_with_body(), $vars );
    unlike( $out, qr{id="ls-admin-bar"},
        'no admin-bar div for non-manager' );
    unlike( $out, qr{id="ls-theme-sel"},
        'no theme switcher for non-manager' );
};

# --- Manager viewing a public page: bar present, switcher absent ---

subtest 'manager visitor: bar emitted, theme switcher removed' => sub {
    local $ENV{HTTP_X_REMOTE_USER}   = 'alice';
    local $ENV{HTTP_X_REMOTE_GROUPS} = 'admins';
    my $vars = {
        manager        => 'enabled',
        manager_path   => '/manager',
        manager_groups => 'admins',
        request_uri    => '/about',
        page_source    => '/about.md',
        auth_user      => 'alice',
        auth_name      => 'Alice',
        layout_name    => 'default',
        theme_name     => 'odcc',
    };

    # Pre-create two themes so the old code path would have rendered
    # a <select> with two options. After SM069 the switcher code is
    # gone; the theme dir walk is gone; neither the <select> nor the
    # theme-activate inline JS appears.
    require File::Path;
    File::Path::make_path("$docroot/lazysite/layouts/default/themes/odcc");
    open my $t1, '>', "$docroot/lazysite/layouts/default/themes/odcc/theme.json" or die $!;
    print $t1 '{"name":"odcc","version":"1.0","layouts":["default"],"config":{}}';
    close $t1;
    File::Path::make_path("$docroot/lazysite/layouts/default/themes/dark");
    open my $t2, '>', "$docroot/lazysite/layouts/default/themes/dark/theme.json" or die $!;
    print $t2 '{"name":"dark","version":"1.0","layouts":["default"],"config":{}}';
    close $t2;

    my $out = main::_inject_admin_bar( html_with_body(), $vars );

    like( $out, qr{id="ls-admin-bar"}, 'admin bar present for manager' );
    like( $out, qr{href="/manager/"},  'Manage link present' );
    like( $out, qr{Sign out},          'Sign out link present' );

    # SM069 primary assertions: no switcher element, no inline JS
    # POSTing to theme-activate from a live page.
    unlike( $out, qr{id="ls-theme-sel"},
        'theme switcher <select> not rendered' );
    unlike( $out, qr{<select},
        'no <select> anywhere in the admin bar markup' );
    unlike( $out, qr{action=theme-activate},
        'no inline POST to theme-activate' );
};

# --- On /manager itself: bar is never injected ---

subtest 'admin bar not injected on /manager pages' => sub {
    local $ENV{HTTP_X_REMOTE_USER}   = 'alice';
    local $ENV{HTTP_X_REMOTE_GROUPS} = 'admins';
    my $vars = {
        manager        => 'enabled',
        manager_path   => '/manager',
        manager_groups => 'admins',
        request_uri    => '/manager/config',
        page_source    => '',
        auth_user      => 'alice',
    };
    my $out = main::_inject_admin_bar( html_with_body(), $vars );
    unlike( $out, qr{id="ls-admin-bar"},
        'no admin bar on /manager/* paths' );
};

done_testing();
