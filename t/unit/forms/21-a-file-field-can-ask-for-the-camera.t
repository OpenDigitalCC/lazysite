#!/usr/bin/perl
# SM905 U3: the form grammar could render `accept`, `multiple` and `required` on a
# file input, and had no way to ask for the camera.
#
# `capture` is the attribute that makes a phone offer the camera directly instead
# of the file picker, and it is the sanctioned route: the site's permissions policy
# blocks getUserMedia, so a script cannot open a camera, while a file input with
# `capture` can. An author who wanted a photograph had to hand-write the input,
# which the forms contract does not allow for content.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(load_processor setup_minimal_site);

my $docroot = tempdir( CLEANUP => 1 );
setup_minimal_site($docroot);
load_processor($docroot);

my $meta = { form => 'test' };

sub render {
    my ($rules) = @_;
    return main::convert_fenced_form(
        "::: form\nphoto | Photo | $rules\nsubmit | Send\n:::\n", $meta );
}

subtest 'bare capture lets the browser choose' => sub {
    my $out = render('file capture');
    like( $out, qr/<input type="file"[^>]* capture>/,
        'the attribute is rendered with no value' )
        or diag("got:\n$out");
};

subtest 'and a value names which camera' => sub {
    like( render('file capture:environment'),
        qr/capture="environment"/, 'the rear camera' );
    like( render('file capture:user'), qr/capture="user"/, 'the front one' );
};

subtest 'anything else is not passed through' => sub {
    # The specification defines those two. An attribute with a value no browser
    # honours is worse than none, because the page looks like it asked.
    my $out = render('file capture:selfie');
    unlike( $out, qr/capture/, 'an unknown value is dropped' )
        or diag( "A value invented here would be rendered and ignored, and the "
            . "author would have no way to tell.\n$out" );
    like( $out, qr/<input type="file"/, 'and the field is still a file input' );
};

subtest 'it composes with the rules that were already there' => sub {
    my $out = render('file required multiple accept:image/* capture:environment');
    like( $out, qr/type="file"/,            'file' );
    like( $out, qr/accept="image\/\*"/,     'accept' );
    like( $out, qr/ multiple/,              'multiple' );
    like( $out, qr/capture="environment"/,  'capture' );
    like( $out, qr/ required/,              'required' );
};

subtest 'a file field that does not ask gets no attribute' => sub {
    unlike( render('file'), qr/capture/,
        'silence is the default, as it was before' );
};

done_testing();
