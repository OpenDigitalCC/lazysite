#!/usr/bin/perl
# SM460: a `scan:` list could not see content in a gated section.
#
# Gating MOVES content out of the docroot (SM286). resolve_scan globbed
# "$scan_root$pattern" and walked beneath it, so a scan inside a protected
# section found NOTHING - and rendered a page that listed nothing,
# successfully. Not an error, not a warning: the author sees an empty list and
# reasonably concludes their content is missing or their pattern is wrong.
# Scan-driven indexes are how blog listings, feature indexes and library pages
# are built, and none of them worked behind a gate.
#
# THE LEAK GUARD IS THE ASSERTION THAT MATTERS and comes first. Making a scan
# see MORE is only safe if what it sees is still filtered; the ACL filter in
# resolve_scan was already written for private entries ("so a page resolved
# from the private store is keyed and checked rather than skipping the branch
# and being listed") and had never received one. This proves it receives them
# now and refuses them.
#
# WHY THIS IS A UNIT TEST AND NOT A RENDER. An earlier version drove full
# renders and every case - including the UNGATED control - returned a bare
# status line with no body, so the assertions were measuring the harness. A
# control that fails is not a result. resolve_scan is callable directly after
# load_processor (t/unit/processor/13 does exactly this), which asks the
# question the finding is about without the render in the way.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(load_processor);

# ONE process, ONE docroot, ONE identity - all three are memoised inside the
# processor ($DOCROOT closes over at load; _scan_identity and $ACL_MAP_CACHE
# latch on first use). So the fixture carries every case at once and the
# requester is ANONYMOUS throughout, which is the requester that matters.
my $docroot = tempdir( CLEANUP => 1 );
my $priv    = "$docroot-lazysite-private";
make_path( "$docroot/lazysite/auth", "$docroot/pub",
    "$priv/intranet", "$priv/library" );

open my $cf, '>', "$docroot/lazysite/lazysite.conf" or die $!;
print {$cf} "site_name: T\nsite_url: http://localhost\n";
close $cf;

# intranet: a read list, so anonymous is REFUSED.
# library:  an owner and NO read list, which does not restrict reading - so it
#           is governed content living in the private store that this requester
#           MAY see. That is the case the defect broke, and keeping it in the
#           same store as the refused one is what makes the pair meaningful.
open my $af, '>', "$docroot/lazysite/auth/acls.json" or die $!;
print {$af} '{"intranet":{"read":["alice"],"owner":"alice"},'
    . '"library":{"owner":"alice"}}';
close $af;

sub page {
    my ( $path, $title ) = @_;
    open my $fh, '>', $path or die $!;
    print {$fh} "---\ntitle: $title\n---\n\nbody\n";
    close $fh;
}
page( "$priv/intranet/a.md", 'SecretA' );
page( "$priv/library/one.md", 'LibOne' );
page( "$priv/library/two.md", 'LibTwo' );
page( "$docroot/pub/b.md",    'PublicB' );
page( "$docroot/index.md",    'Home' );
page( "$docroot/404.md",      'NF' );

delete $ENV{HTTP_X_REMOTE_USER};
delete $ENV{HTTP_X_REMOTE_GROUPS};
load_processor($docroot);

sub titles { return [ sort map { $_->{title} } @{ main::resolve_scan( $_[0] ) } ] }
sub urls   { return [ sort map { $_->{url} } @{ main::resolve_scan( $_[0] ) } ] }

# --- the leak guard ---------------------------------------------------------
my $secret = titles('/intranet/*.md');
is_deeply( $secret, [],
    'LEAK GUARD: an anonymous scan of a refused section lists nothing' )
    or diag( 'A leaked TITLE on a public index is a disclosure even when the '
        . 'page itself is refused. Widening the search is only safe while '
        . 'this holds.' );

# --- the defect -------------------------------------------------------------
my $lib = titles('/library/*.md');
is_deeply( $lib, [ 'LibOne', 'LibTwo' ],
    'a scan of a readable section IN THE PRIVATE STORE finds its content' )
    or diag( 'Before the fix this was empty and the page rendered fine, so '
        . 'the author blamed their pattern.' );

# --- and the paths it hands back -------------------------------------------
#
# SM463's fault in a second place: the URL was derived by stripping the scan
# root off the front, and the private root BEGINS with the scan root - so a
# page found here came back as "-lazysite-private/library/one", a broken link
# that also publishes the store's naming.
my $lib_urls = urls('/library/*.md');
is_deeply( $lib_urls, [ '/library/one', '/library/two' ],
    'and hands back PUBLIC urls, not the private store spelling' )
    or diag( 'Widening the search without fixing the derivation would have '
        . 'introduced this fault rather than found it - SM286 warns that '
        . 'resolution and key derivation must change together.' );

# --- nothing regressed for ordinary content --------------------------------
is_deeply( titles('/pub/*.md'), ['PublicB'],
    'public content still lists' )
    or diag( 'A change that hid everything would pass the leak guard and be '
        . 'useless.' );

# --- one page, one entry ----------------------------------------------------
#
# A stray public copy surviving a move must not double-list. Private wins, the
# same direction Private::resolve takes: the governed copy keeps the ACL
# applying, and stray_public() can still report the leak.
page( "$docroot/library/three.md", 'Stray' ) if make_path("$docroot/library");
page( "$priv/library/three.md",    'Governed' );
my $both = titles('/library/*.md');
is( scalar( grep { /^(?:Stray|Governed)$/ } @{$both} ), 1,
    'a page present in BOTH trees is listed once' );
is_deeply( [ grep { /^(?:Stray|Governed)$/ } @{$both} ], ['Governed'],
    'and it is the governed copy that wins' )
    or diag( 'Listing the public stray would list a page whose ACL no longer '
        . 'applies to what was listed.' );

done_testing();
