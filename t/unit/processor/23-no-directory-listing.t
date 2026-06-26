#!/usr/bin/perl
# SM091: the processor must NEVER emit a directory listing. A request for a
# directory with no index.md returns 404, not a list of the files inside it.
# Auto-index is a dev-server-only opt-in (--auto-index); the processor that
# serves a full install has no such behaviour and must not grow one.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(run_processor setup_minimal_site);

my $docroot = tempdir( CLEANUP => 1 );
setup_minimal_site($docroot);

# a real sub-directory with content but no index.md
make_path("$docroot/private");
for my $f (qw(secret-notes.md budget.md draft.md)) {
    open my $fh, '>', "$docroot/private/$f" or die $!;
    print $fh "---\ntitle: $f\n---\nbody of $f\n";
    close $fh;
}

for my $uri ( '/private/', '/private' ) {
    my $out = run_processor( $docroot, $uri, LAZYSITE_NOCACHE => '1' );
    my ($status) = $out =~ /^Status:\s*(\d+)/m;
    is( $status, 404, "directory request $uri returns 404, not a listing" );
    unlike( $out, qr/secret-notes|budget\.md|draft\.md/,
        "$uri response does not leak the directory's filenames" );
}

# a directory that DOES have index.md still renders that page (not a listing)
make_path("$docroot/section");
open my $sx, '>', "$docroot/section/index.md" or die $!;
print $sx "---\ntitle: Section\n---\nSection index.\n";
close $sx;
open my $sn, '>', "$docroot/section/hidden.md" or die $!;
print $sn "---\ntitle: hidden\n---\nx\n";
close $sn;
my $out = run_processor( $docroot, '/section/', LAZYSITE_NOCACHE => '1' );
like( $out, qr/Section index/, '/section/ renders its index.md' );
unlike( $out, qr/hidden\.md/, '/section/ does not list sibling files' );

done_testing();
