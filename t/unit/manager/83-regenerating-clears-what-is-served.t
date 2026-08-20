#!/usr/bin/perl
# SM433: regenerate-registries cleared a path the server stopped reading.
#
# SM293 step 3 moved the generated registries out of the document root into
# lazysite/cache/registries/<key>/<name>, served on request. The invalidator
# was not moved with them - it went on deleting $root/<name>, the pre-SM293
# location. So the control reported cleared_roots and cleared nothing the
# server reads, and the artefact stayed stale for its full four-hour TTL while
# saying it had done its job.
#
# Measured in the field: two regenerate calls, both reporting success, the
# served sitemap unchanged, after a page had been renamed out of it.
#
# AND THE OLD BEHAVIOUR WAS DESTRUCTIVE. Since SM293 the server returns early
# when $root/<name> exists - "an operator who wrote their OWN sitemap.xml as
# content keeps it" - so the path this used to delete became a supported home
# for operator content, and regenerating would have deleted a hand-written
# sitemap with no warning. Both halves are asserted below, because fixing the
# first without noticing the second would have left a data-loss bug behind a
# now-working control.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use Lazysite::Manager::Files  ();
use Lazysite::Manager::Common ();

sub fixture {
    my $d = tempdir( CLEANUP => 1 );
    make_path( "$d/lazysite/templates/registries",
        "$d/lazysite/cache/registries/_root" );
    open my $c, '>', "$d/lazysite/lazysite.conf" or die $!;
    print {$c} "site_name: T\nsite_url: https://t.example\n";
    close $c;
    for my $t (qw(sitemap.xml llms.txt)) {
        open my $fh, '>', "$d/lazysite/templates/registries/$t.tt" or die $!;
        print {$fh} "template";
        close $fh;
    }
    $Lazysite::Manager::Files::DOCROOT  = $d;
    $Lazysite::Manager::Common::DOCROOT = $d;
    return $d;
}

sub spit { open my $fh, '>', $_[0] or die $!; print {$fh} $_[1]; close $fh }

subtest 'the SERVED artefact is what gets cleared' => sub {
    my $d = fixture();
    spit( "$d/lazysite/cache/registries/_root/sitemap.xml", 'STALE' );
    spit( "$d/lazysite/cache/registries/_root/llms.txt",    'STALE' );

    my $r = Lazysite::Manager::Files::action_regenerate_registries();
    ok( $r->{ok}, 'the control reports success' );

    ok( !-f "$d/lazysite/cache/registries/_root/sitemap.xml",
        'the cached sitemap the server reads is gone' )
        or diag( 'The invalidator deleted $root/<name>, which SM293 stopped '
            . 'serving - so the control reported success and changed nothing '
            . 'a visitor could see, for the full TTL.' );
    ok( !-f "$d/lazysite/cache/registries/_root/llms.txt",
        'and every other registry with it' );
};

subtest 'an operator-authored registry is NOT deleted' => sub {
    # Since SM293 the server prefers $root/<name> if it exists, so that path is
    # a supported place for operator content. The old invalidator deleted it.
    my $d = fixture();
    spit( "$d/sitemap.xml",                                 "MINE - hand written\n" );
    spit( "$d/lazysite/cache/registries/_root/sitemap.xml", 'generated' );

    my $r = Lazysite::Manager::Files::action_regenerate_registries();
    ok( $r->{ok}, 'the control still reports success' );

    ok( -f "$d/sitemap.xml", 'the operator file survives' )
        or diag( 'Deleting content an operator may have written deliberately, '
            . 'during a routine regenerate, with no warning.' );
    open my $fh, '<', "$d/sitemap.xml" or die $!;
    local $/;
    like( <$fh>, qr/hand written/, 'and its content is untouched' );
};

subtest 'and the shadow is REPORTED, since clearing cannot help while it wins'
    => sub {
    # The failure this explains: "I regenerated twice and nothing changed."
    my $d = fixture();
    spit( "$d/sitemap.xml", "shadow\n" );
    my $r = Lazysite::Manager::Files::action_regenerate_registries();

    ok( $r->{shadowed_by_files}, 'the response names the shadowing file(s)' )
        or diag explain $r;
    ok( ( grep { m{sitemap\.xml$} } @{ $r->{shadowed_by_files} || [] } ),
        'naming the file itself, not just a count' );
    like( $r->{note}, qr/served in preference/,
        'and the note says why regenerating will not change what is served' );
    };

subtest 'CONTROL: a clean site reports no shadow and the ordinary note' => sub {
    # Without this, a response that ALWAYS warned would pass the subtest above
    # and be useless.
    my $d = fixture();
    spit( "$d/lazysite/cache/registries/_root/sitemap.xml", 'generated' );
    my $r = Lazysite::Manager::Files::action_regenerate_registries();
    ok( !$r->{shadowed_by_files}, 'no shadow reported when there is none' );
    like( $r->{note}, qr/rebuild on the next/, 'and the ordinary note is given' );
};

done_testing();
