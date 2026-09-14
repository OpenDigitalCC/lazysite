#!/usr/bin/perl
# N141B-A: page-pdf converts a page that lives in the private store.
#
# A page under a draft or read ACL is not at $docroot/$rel - it is in the
# private store, and SM738 gave this plugin a `resolve` callback precisely so it
# could be found. convert() then tested `-f "$docroot/$rel"` BEFORE consulting
# that callback, answered "no such page", and returned. The resolver was never
# reached for the one class of page it exists to serve: the plugin worked only
# on the pages that did not need it.
#
# Reported from the field with the workaround already in place - the agent was
# generating the affected PDFs off-site, which is how a defect like this stays
# quiet: everyone routes around it and nobody files it twice.
#
# A SECOND, QUIETER BUG WENT WITH IT. The size check also measured
# "$docroot/$rel". Whenever the two paths differed, the converter's input limit
# was being applied to a different file from the one it would read.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root site_tempdir);

my $plugin = repo_root() . '/plugins/pandoc.pl';
require $plugin;

my $d = site_tempdir();
my $public  = "$d/public";
my $private = "$d/private";
make_path("$public/open");
make_path("$private/docs");

sub w {
    my ( $p, $t ) = @_;
    open my $fh, '>', $p or die "$p: $!";
    print {$fh} $t;
    close $fh;
}

# The gated page: in the private store, ABSENT from the docroot - which is
# exactly what a protected page looks like on disk.
w( "$private/docs/policy.md", "---\ntitle: Policy\n---\n\nBody.\n" );
w( "$public/open/notes.md",   "---\ntitle: Notes\n---\n\nBody.\n" );

# The store's resolver, in the shape the caller passes it: private first, then
# the docroot.
my $resolve = sub {
    my ($rel) = @_;
    my $p = "$private/$rel";
    return -f $p ? $p : "$public/$rel";
};

ok( !-f "$public/docs/policy.md", 'the gated page is not in the docroot' );
ok( -f "$private/docs/policy.md", 'it is in the private store' );

# --- the gated page is no longer refused as missing ---------------------------
#
# Asserted as "NOT no such page" rather than as a successful conversion: whether
# md-to-pdf is installed on the machine running the suite is not what this is
# about, and making the test depend on it would turn a real regression into a
# skip on exactly the hosts that lack it.
my $r = main::convert(
    docroot => $public,
    path    => 'docs/policy.md',
    resolve => $resolve,
);
isnt( $r->{error} // '', 'no such page',
    'a page in the private store is not reported as missing' )
    or diag( 'convert() is testing -f "$docroot/$rel" before asking the '
        . 'resolver. That path is where a gated page is NOT, so the resolver '
        . 'is never reached for the only pages it was added for.' );

# --- a page that really is absent is still refused ---------------------------
#
# The fix must not turn "missing" into "accepted". The resolver falls back to
# the docroot, where this one is also absent.
my $gone = main::convert(
    docroot => $public,
    path    => 'docs/nothing-here.md',
    resolve => $resolve,
);
is( $gone->{ok}, 0, 'a page that exists in neither tree is still refused' );
is( $gone->{error}, 'no such page', 'and still says so' );

# --- an ordinary public page is unaffected -----------------------------------
my $open = main::convert(
    docroot => $public,
    path    => 'open/notes.md',
    resolve => $resolve,
);
isnt( $open->{error} // '', 'no such page',
    'a public page still resolves, with the resolver in play' );

# --- and with NO resolver at all, the docroot is still the answer ------------
#
# Callers that pass no `resolve` get the old behaviour exactly: this plugin is
# used from surfaces that have no private store to consult.
my $no_res = main::convert( docroot => $public, path => 'open/notes.md' );
isnt( $no_res->{error} // '', 'no such page',
    'a public page converts when no resolver is supplied' );

my $no_res_gated = main::convert( docroot => $public, path => 'docs/policy.md' );
is( $no_res_gated->{error}, 'no such page',
    'and a private-store page is correctly unknown to a caller with no resolver' )
    or diag( 'Without a resolver the plugin has no business finding a page '
        . 'outside the docroot it was handed.' );

done_testing();
