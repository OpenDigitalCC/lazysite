#!/usr/bin/perl
# Regression (field report 2026-07-27): the SM212 token-lifetime control on the
# Sessions & keys page fetched `?action=settings-set` directly - but settings-set
# is a `users` SUB-action, not a top-level manager-API action, so the dispatcher
# rejected it ("Unknown action: settings-set") and the Lifetime control silently
# failed. A user-settings write MUST be tunnelled through action=users (the Users
# page's apiCall does exactly this). Guard every manager page against recurring:
# these sub-actions must never appear as a top-level ?action= in a page's JS.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $dir = repo_root() . '/starter/manager';
opendir my $dh, $dir or BAIL_OUT("no starter/manager dir");
my @pages = sort grep { /\.md\z/ } readdir $dh;
closedir $dh;
ok( @pages, 'manager pages found' );

# `users` sub-actions dispatched inside action_users (body.action), reachable
# ONLY via action=users - never as their own top-level ?action=.
my @SUBACTIONS = qw(settings-set settings-get users-page permissions-grid onboarding-web);

for my $p (@pages) {
    open my $fh, '<', "$dir/$p" or next;
    local $/;
    my $t = <$fh>;
    close $fh;
    for my $a (@SUBACTIONS) {
        unlike( $t, qr/\?action=\Q$a\E\b/,
            "$p: no top-level ?action=$a (route user-settings writes through action=users)" );
    }
}

done_testing;
