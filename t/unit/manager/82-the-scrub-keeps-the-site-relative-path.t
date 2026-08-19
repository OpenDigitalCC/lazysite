#!/usr/bin/perl
# SM386: the path scrub must keep what a caller can act on.
#
# SM378 made the snapshot refusal say why. A partner agent then hit it for real
# on 0.10.15 and got:
#
#   tar: <path>: Cannot open: Permission denied
#
# which names nothing. They could not tell whether tar was failing on the
# private store, the render cache, a lock file, or something under lazysite/ it
# should not be reading at all - and that is the one fact needed to act.
#
# THE GUARD DID NOT COVER ITS OWN OUTPUT. The docroot was replaced with <site>,
# and then a generic absolute-path rule ran whose lookbehind excluded "<" but
# not ">" - so it matched the relative remainder immediately after the
# placeholder it had just written, producing "<site><path>".
#
# RELATIVE ALWAYS, ABSOLUTE NEVER. A site-relative path discloses nothing a
# caller cannot already list; a host path discloses the layout.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper                 ();
use Lazysite::Manager::Backups ();

my $DOC = '/home/someuser/web/example.test/public_html';
local $Lazysite::Manager::Backups::DOCROOT = $DOC;

sub scrub { return Lazysite::Manager::Backups::_scrub_paths( $_[0] ) }

subtest 'a path inside the site keeps its shape' => sub {
    my $got = scrub("tar: $DOC/lazysite/cache/tt/x.ttc: Cannot open: Permission denied");
    like( $got, qr{<site>/lazysite/cache/tt/x\.ttc},
        'the site-relative path survives intact' )
        or diag( "got: $got\n"
            . 'Without it the caller cannot tell the cache from a lock file '
            . 'from the private store, which is the whole diagnostic value.' );
    unlike( $got, qr/\Q$DOC\E/, 'and the real docroot does not appear' );
};

subtest 'the private store is named as itself' => sub {
    my $got = scrub("tar: ${DOC}-lazysite-private/upcoming/a.pdf: Cannot open: Permission denied");
    like( $got, qr{<private>/upcoming/a\.pdf},
        'a private-store path is distinguishable from a docroot one' )
        or diag( "got: $got\n"
            . 'These are different faults with different remedies, and they '
            . 'were previously the same three characters.' );
    unlike( $got, qr/\Q$DOC\E/, 'with no real path disclosed' );
};

subtest 'a path outside the site keeps only its tail' => sub {
    my $got = scrub('tar: /var/lib/something/deep/else.lock: Cannot open: Permission denied');
    like( $got, qr{else\.lock}, 'the artefact is still named' );
    unlike( $got, qr{/var/lib},
        'but the host layout above it is not' )
        or diag( "got: $got\n"
            . 'A remote caller learns what failed, not where the host keeps '
            . 'its files.' );
};

subtest 'the guard covers its own output' => sub {
    # The specific regression: the placeholder is written, and then the next
    # rule matches the text right after it.
    my $got = scrub("tar: $DOC/a/b/c: x");
    unlike( $got, qr/<site><|<site>\s*<path>/,
        'no placeholder is immediately followed by another' )
        or diag( "got: $got\n"
            . 'This is what "<site><path>" looked like, and it is what a rule '
            . 'that does not exclude its own output produces.' );
};

subtest 'multi-line tar output is still capped' => sub {
    my $many = join "\n", map { "tar: $DOC/f$_: Cannot open: Permission denied" } 1 .. 8;
    my $got  = scrub($many);
    my $n    = () = $got =~ /Cannot open/g;
    cmp_ok( $n, '<=', 3, 'the first fault, not the flood' );
};

done_testing();
