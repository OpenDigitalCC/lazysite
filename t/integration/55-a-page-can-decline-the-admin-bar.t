#!/usr/bin/perl
# SM656: the admin bar is controlled by who is looking, not by what the page is.
#
# It is injected for an authenticated user holding `ui`, and that is the only
# lever - a property of the PERSON. That works while every page is a content
# page. On a site carrying an application it stops working: the bar's Edit link
# opens the Markdown of a page whose body is a script, so the fastest way to
# break the application is also the most prominent action offered to the person
# most likely to click it.
#
# The operator who both administers the site and USES the application had two
# options and both were wrong: keep `ui` and meet the bar over a data-entry
# screen, or drop `ui` and lose the manager UI with it.
#
# WHAT IS ASSERTED
#   an ordinary page still gets the bar - this does not turn it off generally
#   `admin_bar: none` suppresses it on that page only
#   a page carrying `api:` or `raw:` declines by DEFAULT - it already said it
#     is not a document, and offering it a Markdown editor was never right
#   an explicit admin_bar wins over that default, so such a page can ask back
#   an anonymous visitor never had it and still does not
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(run_processor);

my $docroot = tempdir( CLEANUP => 1 );
make_path("$docroot/lazysite/auth");
open my $cf, '>', "$docroot/lazysite/lazysite.conf" or die $!;
print {$cf} "site_name: T\nmanager: enabled\n";
close $cf;

sub page {
    my ( $name, $fm ) = @_;
    open my $fh, '>', "$docroot/$name.md" or die $!;
    print {$fh} "---\ntitle: $name\n" . ( $fm // '' ) . "---\n\nBody of $name.\n";
    close $fh;
    return;
}
page( 'ordinary',   '' );
page( 'app',        "admin_bar: none\n" );
page( 'apipage',    "api: true\n" );
page( 'rawpage',    "raw: true\n" );
page( 'apiwantsbar', "api: true\nadmin_bar: show\n" );

sub as_manager {
    return run_processor( $docroot, "/$_[0]",
        LAZYSITE_AUTH_TRUSTED => '1',
        HTTP_X_REMOTE_USER    => 'sjm',
        HTTP_X_REMOTE_GROUPS  => 'sysops' );
}
# THE ADMIN BAR'S OWN LINK, and getting this right took two attempts. The
# chrome stylesheet is on every page; and `id="site-bar"` is the SITE's
# navigation bar - home, sign in, search - which the fallback layout gives
# every visitor and which has nothing to do with the admin bar. The thing
# under test is what _inject_admin_bar adds for a manager: the Edit link into
# the page's own Markdown, which is the action this filing is about.
sub has_bar { return $_[0] =~ m{/manager/edit\?path=} ? 1 : 0 }

# --- the bar still works ---------------------------------------------------
# Without this the fix could be "never inject" and everything below passes.
my $ord = as_manager('ordinary');
ok( has_bar($ord), 'an ordinary page still gets the admin bar' )
    or diag('the bar is gone everywhere - this fix must not do that');

# --- the request ------------------------------------------------------------
my $app = as_manager('app');
ok( !has_bar($app), 'admin_bar: none suppresses it on that page' );
like( $app, qr/Body of app/, 'and the page itself still renders' );

# --- api: and raw: need no rule, and this says why --------------------------
# The filing suggested defaulting them to none as the cheap version. Measured
# while building this: an api: page renders NO <body>, so the injector's own
# first guard returns before anything is added. A default there could never
# fire, and the two assertions that "proved" it passed with the code removed.
# Kept as a statement of the measured fact rather than as a test of a branch
# that does not exist.
like( as_manager('apipage'), qr/\A(?!.*<body)/s,
    'an api: page renders no <body>, so the admin bar cannot reach it anyway '
        . '- which is why no api:/raw: default was added' );
ok( !has_bar( as_manager('apipage') ), 'and it has no admin bar' );

# --- and nothing changed for the public -------------------------------------
my $anon = run_processor( $docroot, '/ordinary' );
ok( !has_bar($anon), 'an anonymous visitor never had the bar and still does not' );

done_testing();
