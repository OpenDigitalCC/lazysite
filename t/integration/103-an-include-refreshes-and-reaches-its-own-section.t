#!/usr/bin/perl
# SM888 A2 + A3 / K4 + K5: two defects in the same three lines of the include
# path.
#
# K4 - EDITING A PARTIAL DID NOT REFRESH THE PAGES THAT INCLUDE IT.
# `_resolve_include` read the file and never recorded it. SM311 built exactly
# the machinery for this - a record of what a render READ, so the cache can
# tell when it has gone stale - and gave it four call sites, none of them in
# the include path. So a shared header, footer or notice edited once updated
# nothing until each including page was saved. That is SM311's own complaint
# one layer along: the person who edits the partial is often not the person
# who can save the pages.
#
# K5 - A PAGE IN A PROTECTED SECTION COULD NOT INCLUDE ITS OWN PARTIALS.
# Gating MOVES content out of the docroot into a SIBLING store (SM286), and
# the include guard asked `_path_under($real, $croot)`. A protected page's
# partial is in the store, not under the content root, so its own neighbour
# was refused as a path traversal - logged as "include path invalid", which
# reads as an attack rather than a feature that does not reach here.
#
# The engine already had the right predicate: `_path_under_content` accepts the
# content root OR its twin in the store, and carries the reasoning for why it
# is not "anywhere in the store" - that would hand every domain access to every
# other domain's protected content.
#
# THE LEAK ASSERTION COMES FIRST, as it does in t/unit/processor/61: widening a
# confinement check is only safe if what it still refuses is still refused.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(setup_test_site run_processor site_tempdir);

my $docroot = site_tempdir();
my $priv    = "$docroot-lazysite-private";
setup_test_site($docroot);
make_path( "$priv/intranet", "$docroot/partials" );

# `library` has an owner and NO read list, so it does not restrict reading: it
# is governed content in the private store that an anonymous visitor may see.
# That is the case K5 broke.
make_path( "$priv/library", "$docroot/lazysite/auth" );
open my $af, '>', "$docroot/lazysite/auth/acls.json" or die $!;
print {$af} '{"intranet":{"read":["alice"],"owner":"alice"},'
    . '"library":{"owner":"alice"}}';
close $af;

sub write_file {
    my ( $path, $text ) = @_;
    ( my $dir = $path ) =~ s{/[^/]+\z}{};
    make_path($dir) unless -d $dir;
    open my $fh, '>', $path or die "$path: $!";
    print {$fh} $text;
    close $fh;
    return;
}

write_file( "$docroot/partials/notice.md", "NOTICE VERSION ONE\n" );
write_file( "$docroot/uses-notice.md",
    "---\ntitle: Uses\n---\n\n::: include\n/partials/notice.md\n:::\n" );

# The protected page and ITS OWN partial, both in the store.
write_file( "$priv/library/_aside.md", "ASIDE FROM THE STORE\n" );
write_file( "$priv/library/page.md",
    "---\ntitle: Lib\n---\n\n::: include\n./_aside.md\n:::\n" );

sub body_of {
    my ($out) = @_;
    $out //= '';
    $out =~ s/\A.*?\r?\n\r?\n//s;
    return $out;
}

sub get {
    my ($url) = @_;
    my $out = run_processor( $docroot, $url );
    return body_of($out);
}

subtest 'the include still refuses what it always refused' => sub {
    # FIRST, because the rest of this file widens a confinement check.
    write_file( "$docroot/leaky.md",
        "---\ntitle: Leak\n---\n\n::: include\n/lazysite/auth/acls.json\n:::\n" );
    my $body = get('/leaky');
    unlike( $body, qr/intranet/,
        'the lazysite/ management tree is still out of reach' )
        or diag( 'An include that reaches lazysite/auth would publish the '
            . 'session secret and the password hashes.' );
    like( $body, qr/include-error/, 'and it says so in the page' );
};

subtest 'K4: editing a partial refreshes the page that includes it' => sub {
    my $first = get('/uses-notice');
    like( $first, qr/NOTICE VERSION ONE/, 'the partial rendered' ) or diag($first);

    # The .md is untouched; only the partial changes. Nothing else in the
    # freshness rule can notice that.
    sleep 1;    # the cache compares mtimes at one-second resolution
    write_file( "$docroot/partials/notice.md", "NOTICE VERSION TWO\n" );

    my $second = get('/uses-notice');
    like( $second, qr/NOTICE VERSION TWO/,
        'the second render carries the EDITED partial' )
        or diag( 'The page served its cached render. A shared header edited '
            . 'once updates nothing until every page including it is saved - '
            . 'and the person who edits the partial often cannot save them.' );
};

subtest 'K5: a protected page includes its own partial' => sub {
    my $body = get('/library/page');
    like( $body, qr/ASIDE FROM THE STORE/,
        "a page in the store reaches its own neighbour" )
        or diag( 'Gating moves content to a SIBLING of the docroot, so a '
            . "protected page's own partial is not under the content root. "
            . 'Refused as a path traversal and logged as one.' );
    unlike( $body, qr/include-error/, 'and no include error is rendered' );
};

done_testing();
