#!/usr/bin/perl
# A manager page's server-rendered shell embeds per-user, capability-gated chrome
# (the nav menu gated on manager_caps). Caching it would serve a STALE menu that
# ignores a just-granted capability until the cache is busted (the "I granted
# manage_domains but the Domains link never appeared without a re-login" bug), and
# would leak one user's capability-gated menu to another via the shared cache. So
# any page that requires auth - notably `auth: manager`, not only `auth: required`
# - must be treated as protected: never written to, nor served from, the .html
# cache. A public `auth: none` page still caches.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(run_processor);

my $d = tempdir( CLEANUP => 1 );
make_path("$d/lazysite/layouts/default");
open my $c, '>', "$d/lazysite/lazysite.conf" or die $!;
# manager_groups unset -> any authenticated user is a manager; auth_proxy_trusted
# lets the test present an identity via X-Remote-User.
print $c "site_name: T\nlayout: default\nmanager: enabled\nauth_proxy_trusted: true\n";
close $c;
open my $l, '>', "$d/lazysite/layouts/default/layout.tt" or die $!;
print $l '<!DOCTYPE html><html><head><title>[% page_title %]</title></head>'
       . '<body><main>[% content %]</main></body></html>';
close $l;
open my $nf, '>', "$d/404.md" or die $!;
print $nf "---\ntitle: NF\n---\nNF.\n";
close $nf;

# A public page and an auth: manager page.
open my $pub, '>', "$d/public.md" or die $!;
print $pub "---\ntitle: Public\n---\nHello.\n";
close $pub;
open my $mgr, '>', "$d/panel.md" or die $!;
print $mgr "---\ntitle: Panel\nauth: manager\n---\nManager only.\n";
close $mgr;

# --- a public page IS cached (control: the fix must not break public caching) --
my $pubout = run_processor( $d, '/public' );
like( $pubout, qr/Hello\./, 'public page renders' );
ok( -f "$d/public.html", 'a public (auth: none) page IS written to the .html cache' );

# --- an auth: manager page is NOT cached, even for an authenticated manager -----
my $mgrout = run_processor( $d, '/panel',
    HTTP_X_REMOTE_USER => 'alice', HTTP_X_REMOTE_GROUPS => '' );
like( $mgrout, qr/Manager only\./, 'manager page renders for an authenticated manager' );
ok( !-f "$d/panel.html",
    'an auth: manager page is NOT written to the shared cache (menu re-renders per request)' );

done_testing;
