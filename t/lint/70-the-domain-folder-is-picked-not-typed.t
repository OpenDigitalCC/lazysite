#!/usr/bin/perl
# SM437: on the create sheet, the content folder is CHOSEN, not typed.
#
# Requested from doing it repeatedly: every domain on the estate is
# sites/<hostname>, retyped by hand each time. A field whose correct value is
# derivable from another field on the same form should not be typed.
#
# The failure it removes is quiet, which is why it earns a guard rather than
# being a nicety. domain_add accepts any clean relative path and provisions it,
# so a typo produces a domain pointing at a new EMPTY directory: the site
# serves, with nothing in it, and the intended content sits one directory away
# under the name that was meant. The typo'd path is perfectly VALID - nothing
# validates its way out of this, which is why the remedy is to stop asking.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $page = repo_root() . '/starter/manager/domains.md';
plan skip_all => 'domains page missing' unless -f $page;
my $src = do { open my $fh, '<', $page or die $!; local $/; <$fh> };

like( $src, qr/action=list&path=\//,
    'the parent list comes from the folders that EXIST' )
    or diag( 'A hand-maintained list of folders is the same typo risk one '
        . 'level up.' );

like( $src, qr/e\.name !== 'lazysite'/,
    'and the system area is never offered as a content root' );

like( $src, qr/return h \? \(sel\.value \+ '\/' \+ h\) : sel\.value;/,
    'the child folder is derived from the HOST, not typed' )
    or diag( 'Deriving it is the whole request - the convention is already '
        . 'sites/<hostname>, maintained by a person, every time.' );

like( $src, qr/content_root: contentRootValue\(\)/,
    'and the submit sends the derived value' )
    or diag( 'A picker that does not reach the request is decoration.' );

# The escape hatch has to exist, or an operator whose layout the convention
# does not cover is stuck behind a dropdown.
like( $src, qr/__custom/, 'a "somewhere else" option keeps the text box reachable' );

# The seed checkbox is conditional on a folder being named (SM259). Under the
# picker the text box is hidden and empty, so a syncSeedVisible that still
# asked the BOX would hide the option permanently.
like( $src, qr/if \(document\.getElementById\('e-' \+ NEW_HOST \+ '-cr-parent'\)\)/,
    'the seed option asks the derived value, not the hidden box' )
    or diag( 'SM259 put the seed option inside the content-folder field and '
        . 'showed it only when a folder is named; the picker must not break '
        . 'that by leaving the box it reads permanently empty.' );

# And the preview must track the host as it is typed - a surprise at submit
# time is too late to be useful.
like( $src, qr/hf\.addEventListener\('input', syncContentRoot\)/,
    'the derived path follows the host field as it is typed' );

done_testing();
