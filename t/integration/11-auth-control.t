#!/usr/bin/perl
# SM099: [% auth_control %] gives a theme a cache-safe sign in/out control - both
# links ship hidden and the injected auth-sync script reveals the right one from
# the lzs_session cookie. So a cached page never bakes in the wrong (anonymous)
# state, unlike a server-side [% IF authenticated %].
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(run_processor);

my $docroot = tempdir( CLEANUP => 1 );
make_path("$docroot/lazysite/layouts/t");

open my $c, '>', "$docroot/lazysite/lazysite.conf" or die $!;
print $c "site_name: Test\nlayout: t\n";
close $c;
open my $l, '>', "$docroot/lazysite/layouts/t/layout.tt" or die $!;
print $l '<!DOCTYPE html><html><head><title>[% page_title %]</title></head>'
       . '<body><header id="bar">[% auth_control %]</header><main>[% content %]</main></body></html>';
close $l;
open my $nf, '>', "$docroot/404.md" or die $!;
print $nf "---\ntitle: NF\n---\nNF.\n";
close $nf;
open my $idx, '>', "$docroot/index.md" or die $!;
print $idx "---\ntitle: Home\n---\nHi.\n";
close $idx;

my $out = run_processor( $docroot, '/' );

like( $out, qr/data-ls-auth-in[^>]*>Sign in</,  'Sign in link present and tagged' );
like( $out, qr/data-ls-auth-out[^>]*>Sign out</, 'Sign out link present and tagged' );
# Both ship hidden - the script decides which to show, so neither state is baked in.
like( $out, qr/data-ls-auth-in[^>]*display:none/,  'Sign in starts hidden' );
like( $out, qr/data-ls-auth-out[^>]*display:none/, 'Sign out starts hidden' );
# The auth-sync toggle script is injected.
like( $out, qr/lzs_session=1/, 'auth-sync toggle script injected' );

done_testing;
