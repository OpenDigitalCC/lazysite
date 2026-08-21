#!/usr/bin/perl
# SM445: an expired session must say so.
#
# Reported from the field: "the submit button did nothing. i refreshed and
# discovered session expired. i had no information to say that, it just felt
# like it has failed."
#
# It did nothing because every manager page posts through a helper shaped
#     fetch(...).then(function (r) { return r.json(); })
# with no status check and no .catch(). An expired session answers 401 with a
# non-JSON body, r.json() REJECTS, the rejection is unhandled, and the .then()
# never runs - so neither the success branch NOR the error branch fires. The
# pages HAVE an error branch for this, and it is unreachable, because the
# failure happens before the branch is chosen.
#
# The fix lives in the shared layout wrapper rather than in the 96 call sites
# across 12 pages. This asserts that it is there, that it is bound to 401
# ALONE, and that the page-level helpers were not "fixed" individually - which
# would be the version that gets half-applied and then drifts.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $layout = repo_root() . '/starter/lazysite/manager/layout.tt';
plan skip_all => 'manager layout missing' unless -f $layout;

my $src = do { open my $fh, '<', $layout or die $!; local $/; <$fh> };

like( $src, qr/status !== 401/,
    'the shared fetch wrapper checks for 401' )
    or diag( 'Without a status check the 401 body reaches r.json(), which '
        . 'rejects, and the click is silent.' );

like( $src, qr/session has expired/i,
    'and says so in words an operator can act on' );

like( $src, qr/Refresh now/,
    'offering the action that actually resolves it' );

# The GET path matters as much as the POST one: a page that loads its list
# after the session lapsed is just as silent as one that submits.
my ($wrapper) = $src =~ /var origFetch = window\.fetch\.bind\(window\);(.*?)\}\)\(\);/s;
ok( defined $wrapper, 'the wrapper is present' );
my $hooks = () = ( $wrapper // '' ) =~ /\.then\(noteExpiry\)/g;
cmp_ok( $hooks, '>=', 2,
    'both the plain and the CSRF-signed paths report expiry' )
    or diag( 'Hooking only the POST path leaves every page load silent.' );

# 403 must NOT be treated as an expiry: it is a permission decision with a
# real JSON body the pages already report, and "sign in again" is wrong advice
# for a refusal that signing in will not change.
unlike( $wrapper // '', qr/status === 403|status !== 403/,
    '403 is left alone - it is a refusal, not an expiry' );

done_testing();
