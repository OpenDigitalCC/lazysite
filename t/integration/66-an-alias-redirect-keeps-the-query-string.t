#!/usr/bin/perl
# SM482: an alias redirect kept the path and threw away the parameters.
#
# FOUND ON A LIVE HOSTING SITE. A hosted customer whose service is down lands
# on
#
#   https://cloudient.net/forms/service-report.shtml?https://their-site/
#
# where the QUERY STRING IS THE AFFECTED SITE - the page reads
# `location.search` and renders "Affected service: <url>" with a link back.
# The legacy .shtml URL is served by an alias, and the alias resolved the path
# and discarded the payload, so the form no longer knew what it was reporting
# on. The 404 that prompted the alias was fixed; the thing the URL existed to
# carry was not.
#
# It is not a special case. `?page=3`, `?utm_source=...`, a search term, a
# tracking parameter - every one of them is somebody's link, and a 301 is
# expected to preserve them. Every other redirect in the processor already did.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root env_passthrough);

my $root    = repo_root();
my $docroot = tempdir( CLEANUP => 1 );
make_path("$docroot/lazysite");
open my $c, '>', "$docroot/lazysite/lazysite.conf" or die $!;
print {$c} "site_name: T\n";
close $c;

# The alias map, as Lazysite::Aliases writes it.
open my $a, '>', "$docroot/lazysite/aliases.json" or die $!;
# `target`, not `url` - the key _alias_lookup actually reads. Writing the wrong
# one produced a 404 and a test that looked like the product was broken.
print {$a} encode_json(
    {   '/forms/service-report.shtml' =>
            { target => '/forms/service-report', code => 301 },
        '/old.shtml'     => { target => '/new',                  code => 301 },
        '/tracked.shtml' => { target => '/landing?src=legacy', code => 301 },
    }
);
close $a;

open my $p, '>', "$docroot/index.md" or die $!;
print {$p} "---\ntitle: Home\n---\n\nHi.\n";
close $p;

sub visit {
    my ( $uri, $qs ) = @_;
    local %ENV = (
        env_passthrough(),
        DOCUMENT_ROOT  => $docroot,
        REDIRECT_URL   => $uri,
        REQUEST_URI    => $uri . ( length( $qs // '' ) ? "?$qs" : '' ),
        QUERY_STRING   => ( $qs // '' ),
        REQUEST_METHOD => 'GET',
        HTTP_HOST      => 'example.test',
    );
    delete $ENV{LAZYSITE_AUTH_TRUSTED};
    my $out = qx($^X \Q$root/lazysite-processor.pl\E 2>/dev/null);
    my ($status) = $out =~ /Status:\s*(\d+)/;
    my ($loc)    = $out =~ /^Location:\s*(\S+)/mi;
    return ( $status // 0, $loc // '', $out );
}

subtest 'THE PAYLOAD SURVIVES THE REDIRECT' => sub {
    # The live case, verbatim.
    my ( $st, $loc ) = visit( '/forms/service-report.shtml',
        'https://ekaterina.media/' );
    is( $st, 301, 'the alias redirects' );
    like( $loc, qr{\Q/forms/service-report\E}, 'to the canonical page' );
    like( $loc, qr{\Qhttps://ekaterina.media/\E},
        'carrying the query string it was given' )
        or diag( "Location: $loc\n"
            . 'The query string IS the affected service. Dropping it leaves '
            . 'the report form with nothing to report on, which is the whole '
            . 'purpose of the URL.' );
};

subtest 'ordinary parameters too - this is not a special case' => sub {
    for my $qs ( 'page=3', 'utm_source=news&utm_medium=email', 'q=a+b' ) {
        my ( undef, $loc ) = visit( '/old.shtml', $qs );
        like( $loc, qr/\Q$qs\E/, "'$qs' survives" )
            or diag( 'Every one of these is somebody\'s link.' );
    }
};

subtest 'a request with no query gets a clean redirect' => sub {
    my ( $st, $loc ) = visit('/old.shtml');
    is( $st, 301, 'it still redirects' );
    is( $loc, '/new', 'with no stray ? on the end' )
        or diag( 'A trailing "?" on every alias redirect would change every '
            . 'canonical URL in the site for the sake of one case.' );
};

subtest 'AN ALIAS THAT CARRIES ITS OWN QUERY KEEPS BOTH' => sub {
    # The target is an author's front-matter string and may already carry
    # parameters. Theirs say where they are sending people; the visitor's are
    # what they arrived with. Replacing one with the other loses information
    # either way, so they are joined.
    my ( undef, $loc ) = visit( '/tracked.shtml', 'page=2' );
    like( $loc, qr/src=legacy/, "the author's parameter is kept" );
    like( $loc, qr/page=2/,     "and the visitor's" );
    # COUNTED, not matched. `qr/\?[^?]*\z/` was the first attempt and it
    # anchors on the LAST question mark, so `/landing?src=legacy?page=2`
    # satisfied it - a regex that cannot fail the thing it was written to
    # catch.
    my $marks = () = $loc =~ /\?/g;
    is( $marks, 1, 'joined with & rather than a second ?' )
        or diag( "Location: $loc - two '?' makes everything after the second "
            . 'part of a parameter value.' );
};

subtest 'the Location header cannot be split' => sub {
    # QUERY_STRING is request-controlled. It reaches a header, so CR and LF
    # come out - the same guard the alias target already had, for the same
    # reason, now applied to the half that comes from outside.
    my ( undef, $loc ) = visit( '/old.shtml', "x=1\r\nX-Injected: yes" );
    unlike( $loc, qr/[\r\n]/, 'no CR or LF reaches the header' );
    my ( undef, undef, $raw ) = visit( '/old.shtml', "x=1\r\nX-Injected: yes" );
    unlike( $raw, qr/^X-Injected:/mi, 'and no header was injected' )
        or diag( 'A request-controlled value in a Location header is a header '
            . 'injection unless it is stripped.' );
};

done_testing();
