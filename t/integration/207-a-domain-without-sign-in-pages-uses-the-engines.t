#!/usr/bin/perl
# SM1048 (P-8): a domain whose content root has no sign-in pages serves the
# engine's own.
#
# The report: "/login, /claim and /forgot return 404 on a domain whose content
# root lacks them, while the primary serves them. Protected pages then redirect
# to a 404." SM201 gave login and claim (and 402/403/404) a three-tier fallback:
# the domain's content root, the primary's root, the protected engine default.
# This holds it for a domain with NO copies anywhere - the content root, the
# primary's root - for every page the sign-in flow sends a visitor to, and
# follows a protected page's redirect to a page that is served.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root run_processor site_tempdir);

my $root    = repo_root();
my $docroot = site_tempdir();

# A fresh install: the starter tree, which ships the protected defaults under
# lazysite/templates/system/ and seeds none of the system pages at the root.
system( 'cp', '-r', "$root/starter/.", $docroot ) == 0 or die 'copy starter';
make_path("$docroot/lazysite/cache");
system( 'cp', "$docroot/lazysite.conf.example", "$docroot/lazysite/lazysite.conf" )
    if -f "$docroot/lazysite.conf.example" && !-f "$docroot/lazysite/lazysite.conf";

# The primary's root copies are removed too: the domain must not depend on them.
unlink "$docroot/$_.md" for qw(login claim forgot logout);

make_path("$docroot/sites/blog");
open my $pf, '>', "$docroot/sites/blog/index.md" or die $!;
print {$pf} "---\ntitle: Blog\n---\n\nHello\n";
close $pf;
open my $mf, '>', "$docroot/sites/blog/members.md" or die $!;
print {$mf} "---\ntitle: Members\nauth: required\n---\n\nMEMBERS-ONLY\n";
close $mf;
open my $cf, '>>', "$docroot/lazysite/lazysite.conf" or die $!;
print {$cf} "\ndomains:\n  - host: blog.example.test\n    content_root: sites/blog\n";
close $cf;

sub status_of { my ($r) = @_; my ($s) = $r =~ /Status:\s*(\d+)/; return $s // 200 }
sub get { return run_processor( $docroot, $_[0], HTTP_HOST => 'blog.example.test' ) }

ok( !-e "$docroot/sites/blog/$_.md", "the domain has no $_.md of its own" ) for qw(login claim forgot logout);
ok( !-e "$docroot/$_.md", "...and the primary's root has none either" ) for qw(login claim forgot logout);

for my $page (qw(login claim forgot logout)) {
    my $out = get("/$page");
    is( status_of($out), 200, "/$page on the domain is served, not 404" )
        or diag( substr( $out, 0, 400 ) );
    unlike( $out, qr/Page not found|404 Not Found/i, '...and is not the not-found page' );
}
like( get('/forgot'), qr/password/i,   '/forgot is the reset page' );
like( get('/logout'), qr/signed out/i, '/logout is the signed-out page' );

# The two defaults added for the sign-in flow are copies of the pages a primary
# is seeded with (SM939 keeps those on a bare install): held equal, so they
# cannot drift.
for my $p (qw(forgot logout)) {
    my $seed = do { local @ARGV = ("$root/starter/$p.md"); local $/; <> };
    my $def = do { local @ARGV = ("$root/starter/lazysite/templates/system/$p.md"); local $/; <> };
    is( $def, $seed, "the protected $p.md default is the seeded page" );
}

# A protected page sends a signed-out visitor to sign in; that page must exist.
my $prot = get('/members');
my ($loc) = $prot =~ /^Location:\s*(\S+)/mi;
ok( defined $loc, 'a protected page redirects a signed-out visitor' ) or diag( substr( $prot, 0, 400 ) );
( my $target = $loc // '' ) =~ s{\Ahttps?://[^/]+}{};
$target =~ s/\?.*//;
is( status_of( get($target) ), 200, "...to $target, which the domain serves" );

# The fallback is still bounded to the system pages.
is( status_of( get('/no-such-page') ), 404, 'a missing ordinary page still 404s' );

done_testing();
